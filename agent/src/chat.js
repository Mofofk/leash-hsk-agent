import { ethers } from "ethers";
import { vaultAsOwner, T, txUrl } from "./chain.js";
import { loadPrefs, savePrefs, net } from "./config.js";
import { readPortfolio, recentEvents, readRisk } from "./portfolio.js";
import { gatherSignals } from "./signals.js";
import { geminiJSON } from "./llm.js";
import { recordReason } from "./decisions.js";
import { runCycle, submit, preflightOf, DECISION_KIND } from "./agent.js";

const SYSTEM = `You are Leash, the chat interface of an AI trading agent on HSKSwap (HSK Chain testnet).
The user's vault holds WHSK and USDT. Risk limits live in the LeashVault smart contract; you change them only by
emitting actions, which the user's owner key signs. The contract has hard caps: slippage <= 10%, price deviation
<= 20%, daily loss <= 50%, stop-loss 0.5%..50% (or 0 = off), TWAP window 60..3600 s, trades/day <= 500.
Translate plain words into concrete numbers. Risk appetite guide:
 conservative: maxTradeUsdt 0.5, maxPositionPct 40, maxSlippagePct 0.5, dailyLossPct 2, stopLossPct 5, cooldownSec 300, maxTradesPerDay 12, targetWhskPct 30
 balanced:     maxTradeUsdt 1,   maxPositionPct 70, maxSlippagePct 1,   dailyLossPct 5, stopLossPct 10, cooldownSec 120, maxTradesPerDay 24, targetWhskPct 50
 aggressive:   maxTradeUsdt 2,   maxPositionPct 100, maxSlippagePct 2,  dailyLossPct 10, stopLossPct 20, cooldownSec 60, maxTradesPerDay 48, targetWhskPct 80
"Trade frequency" maps to cooldownSec, maxTradesPerDay and loopSeconds. "Target assets" maps to set_asset and targetWhskPct.
Available actions (any number, in order):
 {"type":"update_risk","params":{maxTradeUsdt?,maxPositionPct?,maxSlippagePct?,maxDeviationPct?,dailyLossPct?,stopLossPct?,cooldownSec?,maxTradesPerDay?,twapWindowSec?}}
 {"type":"set_preferences","prefs":{riskAppetite?,targetWhskPct?,rebalanceBandPct?,arbMinEdgeBps?,loopSeconds?}}
 {"type":"set_asset","symbol":"WHSK","allowed":true|false}
 {"type":"pause","reason":"..."}  {"type":"resume"}
 {"type":"trade_now","side":"BUY"|"SELL","amountWhsk"?:number,"amountUsdt"?:number}   (agent submits it; the vault may block it)
 {"type":"run_cycle"}
HARD RULES: Only emit update_risk when the user explicitly asks to change a limit, risk appetite, size cap, frequency or stop-loss.
A trade request NEVER changes limits: if the trade looks larger than the limits, still emit trade_now and let the vault decide
(it will block it on-chain); say so in the reply. Tightening applies at once; loosening any limit is timelocked on-chain
(the vault queues it for the loosen delay), so tell the user when a change is only queued.
Answer questions about positions, P&L, trades and limits from the state given; use exact numbers, USDT units, 2-4 decimals.
Return JSON: {"reply":"<concise answer for the user, plain text>","actions":[...]}`;

function toParams(cur, p) {
  const n = { ...cur };
  if (p.maxTradeUsdt != null) n.maxTradeQuote = ethers.parseEther(String(p.maxTradeUsdt));
  const pct = (k, field) => { if (p[k] != null) n[field] = Math.round(Number(p[k]) * 100); };
  pct("maxPositionPct", "maxPositionBps"); pct("maxSlippagePct", "maxSlippageBps"); pct("maxDeviationPct", "maxDeviationBps");
  pct("dailyLossPct", "dailyLossBps"); pct("stopLossPct", "stopLossBps");
  if (p.cooldownSec != null) n.cooldown = Math.round(p.cooldownSec);
  if (p.maxTradesPerDay != null) n.maxTradesPerDay = Math.round(p.maxTradesPerDay);
  if (p.twapWindowSec != null) n.twapWindow = Math.round(p.twapWindowSec);
  return n;
}

export async function handleChat(message) {
  const [pf, events, prefs] = await Promise.all([readPortfolio(), recentEvents(10), Promise.resolve(loadPrefs())]);
  let sig = null;
  if (/price|signal|spread|arb|market|opportunit/i.test(message)) sig = await gatherSignals(ethers.parseEther("0.01")).catch(() => null);
  const state = { portfolio: { ...pf, riskRaw: undefined }, recentEvents: events, preferences: prefs, signals: sig, explorer: net.explorer };
  const { model, data } = await geminiJSON(SYSTEM, `STATE:\n${JSON.stringify(state)}\n\nUSER: ${message}`, { temperature: 0.1 });
  const results = [];
  for (const a of data.actions || []) {
    try {
      if (a.type === "update_risk") {
        const cur = await readRisk();
        const next = toParams(cur, a.params || {});
        const tx = await vaultAsOwner.setRiskParams(next, message.slice(0, 200));
        const rc = await tx.wait();
        const queued = rc.logs.map((l) => { try { return vaultAsOwner.interface.parseLog(l); } catch { return null; } }).find((e) => e?.name === "RiskParamsQueued");
        results.push({ action: queued ? "update_risk (looser → TIMELOCKED, effective " + new Date(Number(queued.args.effectiveAt) * 1000).toISOString().slice(11, 16) + " UTC)" : "update_risk (tighter → applied now)", params: a.params, tx: tx.hash, url: txUrl(tx.hash) });
      } else if (a.type === "set_preferences") {
        const p = { ...loadPrefs(), ...a.prefs };
        savePrefs(p);
        results.push({ action: "set_preferences", prefs: a.prefs });
      } else if (a.type === "set_asset") {
        const t = T[a.symbol];
        if (!t) throw new Error(`unknown asset ${a.symbol}`);
        const ref = Object.values(net.pools)[0].address;
        const tx = await vaultAsOwner.configureToken(t.address, ref, !!a.allowed);
        await tx.wait();
        results.push({ action: "set_asset", symbol: a.symbol, allowed: !!a.allowed, tx: tx.hash, url: txUrl(tx.hash) });
      } else if (a.type === "pause") {
        const tx = await vaultAsOwner.pause(a.reason || "paused from chat");
        await tx.wait();
        results.push({ action: "pause", tx: tx.hash, url: txUrl(tx.hash) });
      } else if (a.type === "resume") {
        const tx = await vaultAsOwner.unpause();
        await tx.wait();
        results.push({ action: "resume", tx: tx.hash, url: txUrl(tx.hash) });
      } else if (a.type === "trade_now") {
        const buy = a.side === "BUY";
        const req = buy
          ? { kind: "swap", tokenIn: T.USDT.address, tokenOut: T.WHSK.address, fee: 500, amountIn: ethers.parseEther(String(a.amountUsdt ?? 0)) }
          : { kind: "swap", tokenIn: T.WHSK.address, tokenOut: T.USDT.address, fee: 500, amountIn: ethers.parseEther(String(a.amountWhsk ?? 0)) };
        const pre = await preflightOf(req);
        const hash = recordReason({ v: 1, kind: "user-trade", at: new Date().toISOString(), model, instruction: message, action: a, preflight: pre });
        const r = await submit(req, hash, `USER: ${a.side} ${a.amountWhsk ?? a.amountUsdt} ${a.amountWhsk != null ? "WHSK" : "USDT"}`.slice(0, 120));
        results.push({ action: "trade_now", preflight: pre, ...r, reasonHash: hash });
      } else if (a.type === "run_cycle") {
        const r = await runCycle();
        results.push({ action: "run_cycle", choice: r.decision.choice, memo: r.decision.memo, ...r.result });
      }
    } catch (e) {
      results.push({ action: a.type, error: e.shortMessage || e.message });
    }
  }
  return { model, reply: data.reply, actions: data.actions || [], results };
}

export function renderResults(results) {
  return results
    .map((r) => {
      if (r.error) return `✗ ${r.action} failed: ${r.error}`;
      if (r.blockedBy) return `⛔ ${r.action}: vault BLOCKED it on-chain (${r.blockedBy}) ${r.url}`;
      if (r.url) return `✓ ${r.action}${r.event ? " → " + r.event : ""} ${r.url}`;
      return `✓ ${r.action} ${JSON.stringify(r.prefs || r.params || "")}`;
    })
    .join("\n");
}
