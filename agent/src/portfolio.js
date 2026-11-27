import { ethers } from "ethers";
import { vaultRead, provider, T, symbolOf } from "./chain.js";
import { net, BLOCK_CODES } from "./config.js";

const bps = (x) => Number(x) / 100;

export async function readRisk() {
  const r = await vaultRead.risk();
  return {
    maxTradeQuote: r.maxTradeQuote, maxPositionBps: Number(r.maxPositionBps), maxSlippageBps: Number(r.maxSlippageBps),
    maxDeviationBps: Number(r.maxDeviationBps), dailyLossBps: Number(r.dailyLossBps), stopLossBps: Number(r.stopLossBps),
    cooldown: Number(r.cooldown), maxTradesPerDay: Number(r.maxTradesPerDay), twapWindow: Number(r.twapWindow),
  };
}

export function riskHuman(r) {
  return {
    maxTradeUsdt: Number(ethers.formatEther(r.maxTradeQuote)), maxPositionPct: bps(r.maxPositionBps),
    maxSlippagePct: bps(r.maxSlippageBps), maxDeviationPct: bps(r.maxDeviationBps), dailyLossPct: bps(r.dailyLossBps),
    stopLossPct: bps(r.stopLossBps), cooldownSec: r.cooldown, maxTradesPerDay: r.maxTradesPerDay, twapWindowSec: r.twapWindow,
  };
}

export async function readPortfolio() {
  const [navW, pnl, paused, tokens, risk, tradeCount, blockedCount, tradesToday, lastTradeAt, agent, owner] = await Promise.all([
    vaultRead.nav(), vaultRead.pnl(), vaultRead.paused(), vaultRead.tokens(), readRisk(), vaultRead.tradeCount(),
    vaultRead.blockedCount(), vaultRead.tradesToday(), vaultRead.lastTradeAt(), vaultRead.agent(), vaultRead.owner(),
  ]);
  const positions = [];
  for (const t of tokens) {
    const [balance, cost, value, pTwap, pSpot] = await vaultRead.position(t);
    const allowed = await vaultRead.allowedToken(t);
    positions.push({
      symbol: symbolOf(t), address: t, allowed, balance: Number(ethers.formatEther(balance)),
      costUsdt: Number(ethers.formatEther(cost)), valueUsdt: Number(ethers.formatEther(value)),
      priceTwap: Number(ethers.formatEther(pTwap)), priceSpot: Number(ethers.formatEther(pSpot)),
      unrealizedUsdt: Number(ethers.formatEther(value - cost)),
    });
  }
  const nav = Number(ethers.formatEther(navW));
  const pendingAt = Number(await vaultRead.pendingRiskAt());
  return {
    vault: net.vault, owner, agent, paused, navUsdt: nav,
    pendingLoosening: pendingAt ? { effectiveAt: new Date(pendingAt * 1000).toISOString(), params: riskHuman(await (async () => { const r = await vaultRead.pendingRisk(); return { maxTradeQuote: r.maxTradeQuote, maxPositionBps: Number(r.maxPositionBps), maxSlippageBps: Number(r.maxSlippageBps), maxDeviationBps: Number(r.maxDeviationBps), dailyLossBps: Number(r.dailyLossBps), stopLossBps: Number(r.stopLossBps), cooldown: Number(r.cooldown), maxTradesPerDay: Number(r.maxTradesPerDay), twapWindow: Number(r.twapWindow) }; })()) } : null,
    pnl: { totalUsdt: Number(ethers.formatEther(pnl[0])), realizedUsdt: Number(ethers.formatEther(pnl[1])), unrealizedUsdt: Number(ethers.formatEther(pnl[2])) },
    positions: positions.map((p) => ({ ...p, weightPct: nav ? +((p.valueUsdt / nav) * 100).toFixed(2) : 0 })),
    risk: riskHuman(risk), riskRaw: risk,
    stats: { tradeCount: Number(tradeCount), blockedCount: Number(blockedCount), tradesToday: Number(tradesToday), lastTradeAt: Number(lastTradeAt) },
  };
}

export async function recentEvents(limit = 12) {
  const latest = await provider.getBlockNumber();
  const from = net.vaultDeployBlock || Math.max(0, latest - 200000);
  const logs = [];
  for (let s = from; s <= latest; s += 5000) {
    logs.push(...(await provider.getLogs({ address: net.vault, fromBlock: s, toBlock: Math.min(latest, s + 4999) })));
  }
  const out = [];
  for (const l of logs) {
    let ev;
    try { ev = vaultRead.interface.parseLog(l); } catch { continue; }
    if (!ev) continue;
    const a = ev.args;
    const base = { event: ev.name, tx: l.transactionHash, block: l.blockNumber };
    if (ev.name === "TradeExecuted")
      out.push({ ...base, id: Number(a.id), tokenIn: symbolOf(a.tokenIn), tokenOut: symbolOf(a.tokenOut), fee: Number(a.fee),
        amountIn: ethers.formatEther(a.amountIn), amountOut: ethers.formatEther(a.amountOut), minOut: ethers.formatEther(a.minAmountOut),
        realizedPnl: ethers.formatEther(a.realizedPnl), reasonHash: a.reasonHash, memo: a.memo });
    else if (ev.name === "TradeBlocked")
      out.push({ ...base, id: Number(a.id), code: BLOCK_CODES[Number(a.code)], tokenIn: symbolOf(a.tokenIn), tokenOut: symbolOf(a.tokenOut),
        amountIn: ethers.formatEther(a.amountIn), reasonHash: a.reasonHash, memo: a.memo });
    else if (ev.name === "ArbitrageExecuted")
      out.push({ ...base, id: Number(a.id), legs: `${symbolOf(a.tokenA)}→${symbolOf(a.tokenB)} @${Number(a.feeSell)} / back @${Number(a.feeBuy)}`,
        amountIn: ethers.formatEther(a.amountIn), amountOut: ethers.formatEther(a.amountOut), reasonHash: a.reasonHash, memo: a.memo });
    else if (ev.name === "Decision") out.push({ ...base, id: Number(a.id), kind: Number(a.kind), reasonHash: a.reasonHash, memo: a.memo });
    else if (ev.name === "RiskParamsUpdated") out.push({ ...base, instruction: a.instruction });
    else if (ev.name === "RiskParamsQueued") out.push({ ...base, instruction: a.instruction, effectiveAt: Number(a.effectiveAt), note: "looser limits queued behind the timelock" });
    else if (["Paused", "Unpaused", "StopLossTriggered", "Deposited", "Withdrawn"].includes(ev.name))
      out.push({ ...base, detail: ev.name === "Paused" ? a.reason : undefined });
  }
  return out.slice(-limit).reverse();
}

// LeashLend lending pool (read-only stats for chat and /api/state). Never executes anything.
const LEND_ABI = [
  "function stats() view returns (uint256 cash,uint256 totalDebt,uint256 totalCollateral,uint256 twapPrice,uint256 utilizationBps,bool sane,bool paused)",
  "function position(address) view returns (uint256 collateral,uint256 debt,uint256 collateralValue,uint256 maxBorrow,uint256 available,uint256 healthFactor)",
];
export async function readLending(user) {
  if (!net.lend) return null;
  const L = new ethers.Contract(net.lend.address, LEND_ABI, provider);
  const e = (x) => Number(ethers.formatEther(x));
  const s = await L.stats();
  const out = {
    contract: net.lend.address, collateral: "WHSK", debtAsset: "USDT", testnetOnly: true, audited: false,
    maxLtvPct: net.lend.ltvBps / 100, liquidationThresholdPct: net.lend.liqThresholdBps / 100, liquidationBonusPct: net.lend.liqBonusBps / 100,
    borrowAprPct: net.lend.aprBps / 100, oracle: `HSKSwap WHSK/USDT 0.05% pool TWAP (${net.lend.twapWindowSec}s), spot within ~5% of TWAP`,
    availableLiquidityUsdt: e(s.cash), totalBorrowedUsdt: e(s.totalDebt), totalCollateralWhsk: e(s.totalCollateral),
    whskPriceUsdt: e(s.twapPrice), utilizationPct: Number(s.utilizationBps) / 100, oracleHealthy: s.sane, paused: s.paused,
    howToUse: "Open the dashboard's Borrow section, connect a wallet on HSK Chain testnet, Wrap HSK -> WHSK, Approve, Deposit, Borrow; Repay and Withdraw the same way.",
  };
  if (user) {
    const p = await L.position(user);
    out.position = { address: user, collateralWhsk: e(p.collateral), debtUsdt: e(p.debt), collateralValueUsdt: e(p.collateralValue), canBorrowUsdt: e(p.available), healthFactor: p.debt === 0n ? null : e(p.healthFactor) };
  }
  return out;
}
