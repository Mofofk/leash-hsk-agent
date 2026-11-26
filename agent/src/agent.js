import { ethers } from "ethers";
import { vaultAsAgent, vaultRead, T, txUrl } from "./chain.js";
import { BLOCK_CODES, loadPrefs } from "./config.js";
import { gatherSignals } from "./signals.js";
import { readPortfolio } from "./portfolio.js";
import { geminiJSON } from "./llm.js";
import { recordReason } from "./decisions.js";

const WHSK = T.WHSK.address;
const USDT = T.USDT.address;
export const DECISION_KIND = { HOLD: 0, SIGNAL: 1, PARAMS: 2, USER: 3 };

/// Candidate trades from deterministic signal rules. The LLM chooses among these (or HOLD) and explains why;
/// it cannot invent a trade outside them, and the vault re-checks every limit on-chain anyway.
export function candidates(sig, pf, prefs) {
  const out = [];
  const maxUsdt = pf.risk.maxTradeUsdt;
  const price = pf.positions.find((p) => p.symbol === "WHSK")?.priceTwap || sig.pools[0].spot;
  const whsk = pf.positions.find((p) => p.symbol === "WHSK");
  const usdt = pf.positions.find((p) => p.symbol === "USDT");
  const sizeWhsk = Math.min((maxUsdt * 0.9) / price, whsk?.balance || 0);

  const best = sig.arbitrage[0];
  if (best && best.edgeBps > prefs.arbMinEdgeBps && sizeWhsk > 0)
    out.push({ id: "ARB", action: "ARBITRAGE", sellFee: best.sellFee, buyFee: best.buyFee, amountWhsk: +sizeWhsk.toFixed(6),
      why: `Quoted round trip WHSK→USDT on ${best.sellFee / 1e4}% pool and back on ${best.buyFee / 1e4}% pool returns ${best.edgeBps} bps more WHSK.` });

  const w = whsk?.weightPct || 0;
  const target = prefs.targetWhskPct;
  if (w > target + prefs.rebalanceBandPct && whsk.balance > 0) {
    const excessUsdt = ((w - target) / 100) * pf.navUsdt;
    const amt = Math.min(excessUsdt, maxUsdt * 0.9) / price;
    out.push({ id: "REB_SELL", action: "SELL", fee: 500, amountWhsk: +amt.toFixed(6), why: `WHSK weight ${w}% is above the ${target}% target (${prefs.riskAppetite}).` });
  } else if (w < target - prefs.rebalanceBandPct && (usdt?.balance || 0) > 0) {
    const gapUsdt = Math.min(((target - w) / 100) * pf.navUsdt, maxUsdt * 0.9, usdt.balance);
    out.push({ id: "REB_BUY", action: "BUY", fee: 500, amountUsdt: +gapUsdt.toFixed(6), why: `WHSK weight ${w}% is below the ${target}% target (${prefs.riskAppetite}).` });
  }
  if (Math.abs(sig.momentumBps) > 150) {
    if (sig.momentumBps > 0 && (usdt?.balance || 0) > 0)
      out.push({ id: "MOM_BUY", action: "BUY", fee: 500, amountUsdt: +Math.min(maxUsdt * 0.5, usdt.balance).toFixed(6), why: `Spot is ${sig.momentumBps} bps above the 30-min TWAP (up-trend).` });
    if (sig.momentumBps < 0 && (whsk?.balance || 0) > 0)
      out.push({ id: "MOM_SELL", action: "SELL", fee: 500, amountWhsk: +Math.min((maxUsdt * 0.5) / price, whsk.balance).toFixed(6), why: `Spot is ${-sig.momentumBps} bps below the 30-min TWAP (down-trend).` });
  }
  return out;
}

const SYSTEM = `You are Leash, an autonomous trading agent for HSKSwap (a Uniswap-V3-style DEX) on HSK Chain.
You manage a vault whose limits are enforced by a smart contract you cannot change. Choose exactly one of the
candidate trades provided, or HOLD. Prefer risk-free atomic arbitrage when available, then rebalancing toward the
user's target, then momentum. Never pick a trade that the pre-flight check says the vault would block.
Return JSON: {"choice": "<candidate id or HOLD>", "confidence": 0-1, "memo": "<= 80 chars, plain English>", "reasoning": "2-4 sentences"}`;

export async function decide({ sig, pf, prefs, cands, preflight }) {
  const user = JSON.stringify({
    userPreferences: prefs,
    vault: { navUsdt: pf.navUsdt, pnl: pf.pnl, positions: pf.positions.map(({ symbol, balance, valueUsdt, weightPct }) => ({ symbol, balance, valueUsdt, weightPct })), limits: pf.risk, paused: pf.paused },
    signals: { pools: sig.pools.map(({ name, spot, twap5m, twap30m, deviationBps }) => ({ name, spot, twap5m, twap30m, deviationBps })), feeTierSpreadBps: sig.feeTierSpreadBps, arbitrage: sig.arbitrage, momentumBps: sig.momentumBps, reference: sig.reference },
    candidates: cands.map((c) => ({ ...c, preflight: preflight[c.id] })),
  });
  try {
    const { model, data } = await geminiJSON(SYSTEM, user);
    return { model, ...data };
  } catch (e) {
    const ok = cands.find((c) => preflight[c.id] === "NONE");
    return { model: "rule-fallback", choice: ok ? ok.id : "HOLD", confidence: 0.5, memo: ok ? ok.why.slice(0, 80) : "No safe opportunity", reasoning: `LLM unavailable (${e.message}); deterministic fallback.` };
  }
}

export function toRequest(c, prefs) {
  if (c.action === "ARBITRAGE") return { kind: "arb", amountIn: ethers.parseEther(String(c.amountWhsk)), sellFee: c.sellFee, buyFee: c.buyFee, minProfitBps: Math.max(10, Math.floor(prefs.arbMinEdgeBps / 2)) };
  if (c.action === "SELL") return { kind: "swap", tokenIn: WHSK, tokenOut: USDT, fee: c.fee || 500, amountIn: ethers.parseEther(String(c.amountWhsk)) };
  return { kind: "swap", tokenIn: USDT, tokenOut: WHSK, fee: c.fee || 500, amountIn: ethers.parseEther(String(c.amountUsdt)) };
}

export async function preflightOf(req) {
  const [code] = await vaultRead.checkTrade(req.kind === "arb" ? WHSK : req.tokenIn, req.kind === "arb" ? USDT : req.tokenOut, req.kind === "arb" ? req.sellFee : req.fee, req.amountIn);
  return BLOCK_CODES[Number(code)];
}

/// Sends the request to the vault. The vault either executes it or emits TradeBlocked; both are on-chain.
export async function submit(req, reasonHash, memo) {
  let tx;
  if (req.kind === "arb") {
    tx = await vaultAsAgent.executeArbitrage({ tokenA: WHSK, tokenB: USDT, feeSell: req.sellFee, feeBuy: req.buyFee, amountIn: req.amountIn, minProfitBps: req.minProfitBps, reasonHash, memo }, { gasLimit: 900000 });
  } else {
    tx = await vaultAsAgent.executeSwap({ tokenIn: req.tokenIn, tokenOut: req.tokenOut, fee: req.fee, amountIn: req.amountIn, minAmountOut: 0, reasonHash, memo }, { gasLimit: 700000 });
  }
  const rc = await tx.wait();
  const parsed = rc.logs.map((l) => { try { return vaultRead.interface.parseLog(l); } catch { return null; } }).filter(Boolean);
  const ev = parsed.find((e) => ["TradeExecuted", "TradeBlocked", "ArbitrageExecuted"].includes(e.name));
  const result = { tx: rc.hash, url: txUrl(rc.hash), event: ev?.name };
  if (ev?.name === "TradeBlocked") result.blockedBy = BLOCK_CODES[Number(ev.args.code)];
  if (ev?.name === "TradeExecuted") Object.assign(result, { amountIn: ethers.formatEther(ev.args.amountIn), amountOut: ethers.formatEther(ev.args.amountOut), minOut: ethers.formatEther(ev.args.minAmountOut) });
  if (ev?.name === "ArbitrageExecuted") Object.assign(result, { amountIn: ethers.formatEther(ev.args.amountIn), amountOut: ethers.formatEther(ev.args.amountOut) });
  return result;
}

export async function logDecision(kind, reasonHash, memo) {
  const tx = await vaultAsAgent.logDecision(kind, reasonHash, memo.slice(0, 120));
  const rc = await tx.wait();
  return { tx: rc.hash, url: txUrl(rc.hash), event: "Decision" };
}

/// One autonomous cycle: observe -> candidates -> pre-flight -> LLM decision -> on-chain execution + audit log.
export async function runCycle({ log = console.log } = {}) {
  const prefs = loadPrefs();
  const pf = await readPortfolio();
  const sizeProbe = ethers.parseEther(String(Math.max(0.001, Math.min(pf.risk.maxTradeUsdt * 0.9 / (pf.positions.find((p) => p.symbol === "WHSK")?.priceTwap || 50), 1)).toFixed(6)));
  const sig = await gatherSignals(sizeProbe);
  const cands = candidates(sig, pf, prefs);
  const preflight = {};
  for (const c of cands) preflight[c.id] = await preflightOf(toRequest(c, prefs));
  const d = await decide({ sig, pf, prefs, cands, preflight });
  const chosen = cands.find((c) => c.id === d.choice);
  const reason = { v: 1, kind: "cycle", at: sig.at, model: d.model, choice: d.choice, confidence: d.confidence, memo: d.memo, reasoning: d.reasoning, candidates: cands, preflight, signals: sig, portfolio: { navUsdt: pf.navUsdt, pnl: pf.pnl, positions: pf.positions }, limits: pf.risk, prefs };
  const hash = recordReason(reason);
  const memo = `${d.choice}: ${d.memo || ""}`.slice(0, 120);
  let result;
  if (!chosen || pf.paused) result = await logDecision(DECISION_KIND.HOLD, hash, memo);
  else result = await submit(toRequest(chosen, prefs), hash, memo);
  log(`[cycle] ${memo} -> ${result.event}${result.blockedBy ? " (" + result.blockedBy + ")" : ""} ${result.url}`);
  return { decision: d, candidates: cands, preflight, reasonHash: hash, result };
}
