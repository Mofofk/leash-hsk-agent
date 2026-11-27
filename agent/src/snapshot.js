// Records the exact JSON-RPC answers the dashboard needs into dashboard/snapshot.json, so the hosted
// dashboard can still render (marked as a snapshot) when a visitor's network can't reach the HSK RPC.
import { ethers, FetchRequest } from "ethers";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const html = fs.readFileSync(path.join(ROOT, "dashboard/index.html"), "utf8");
const ABI = eval(html.match(/const ABI = (\[[\s\S]*?\n\]);/)[1]);
const POOL_ABI = eval(html.match(/const POOL_ABI = (\[[^\n]*\]);/)[1]);
const LEND_ABI = eval(html.match(/const LEND_ABI = (\[[^\n]*\]);/)[1]);

// keep identical to rk() in dashboard/index.html
export function rk(q) {
  const p = q.params || [];
  switch (q.method) {
    case "eth_call": return "call|" + String(p[0].to).toLowerCase() + "|" + p[0].data + "|" + (p[1] === "latest" || p[1] === undefined ? "latest" : parseInt(p[1], 16));
    case "eth_getLogs": return "logs|" + String(p[0].address).toLowerCase() + "|" + parseInt(p[0].fromBlock, 16) + "|" + parseInt(p[0].toBlock, 16);
    case "eth_getBlockByNumber": return "blk|" + parseInt(p[0], 16);
    case "eth_blockNumber": return "bn";
    default: return q.method + "|" + JSON.stringify(p);
  }
}

export async function writeSnapshot() {
  const D = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments.json"), "utf8"))["hsk-testnet"];
  const cache = {};
  const fr = new FetchRequest(D.rpc);
  const base = FetchRequest.createGetUrlFunc();
  fr.getUrlFunc = async (req, signal) => {
    const resp = await base(req, signal);
    try {
      const qs = JSON.parse(new TextDecoder().decode(req.body)); const rs = JSON.parse(new TextDecoder().decode(resp.body));
      const qa = Array.isArray(qs) ? qs : [qs], ra = Array.isArray(rs) ? rs : [rs];
      for (const q of qa) { const r = ra.find((x) => x.id === q.id); if (r && r.result !== undefined) cache[rk(q)] = r.result; }
    } catch {}
    return resp;
  };
  const provider = new ethers.JsonRpcProvider(fr, D.chainId, { staticNetwork: true, batchMaxCount: 1 });
  const vault = new ethers.Contract(D.vault, ABI, provider);
  const latest = await provider.getBlockNumber();
  const L = (c) => vault[c]({ blockTag: "latest" });
  const [, , , toks] = await Promise.all([L("nav"), L("pnl"), L("paused"), L("tokens"), L("risk"), L("tradeCount"), L("blockedCount"), L("tradesToday"), L("owner")]);
  for (const t of toks) await vault.position(t);
  const [pAt] = await Promise.all([vault.pendingRiskAt(), vault.loosenDelay()]);
  if (Number(pAt)) await vault.pendingRisk();
  const LOGS = [];
  for (let s = D.vaultDeployBlock; s <= latest; s += 5000) {
    const raw = await provider.getLogs({ address: D.vault, fromBlock: s, toBlock: Math.min(latest, s + 4999) });
    for (const l of raw) { let ev = null; try { ev = vault.interface.parseLog(l); } catch {} if (ev) LOGS.push({ l, ev }); }
  }
  // Borrow section: LeashLend pool stats (read-only view)
  if (D.lend) { try { await new ethers.Contract(D.lend.address, LEND_ABI, provider).stats({ blockTag: "latest" }); } catch {} }
  for (const p of Object.values(D.pools)) {
    const pool = new ethers.Contract(p.address, POOL_ABI, provider);
    await Promise.all([pool.slot0(), pool.token0()]); try { await pool.observe([300, 0]); } catch {}
  }
  // same sampling as history() in the dashboard
  const KIND = (n) => ({ TradeExecuted: "trade", ArbitrageExecuted: "arb", TradeBlocked: "blocked", Decision: "hold" })[n] || "admin";
  const acts = LOGS.filter(({ ev }) => ["TradeExecuted", "ArbitrageExecuted", "TradeBlocked", "Decision", "Deposited", "Withdrawn", "StopLossTriggered"].includes(ev.name));
  const moving = [...new Set(acts.filter(({ ev }) => ev.name !== "Decision" && ev.name !== "TradeBlocked").map(({ l }) => l.blockNumber))];
  let blocks = [D.vaultDeployBlock + 1, ...moving, latest];
  if (blocks.length > 70) blocks = blocks.filter((_, i) => i % Math.ceil(blocks.length / 70) === 0).concat([latest]);
  blocks = [...new Set(blocks)].sort((a, b) => a - b);
  const tb = new Set(blocks);
  for (const b of blocks) { try { await Promise.all([vault.nav({ blockTag: b }), vault.pnl({ blockTag: b })]); } catch { tb.delete(b); } }
  for (const { l, ev } of acts) if (["TradeExecuted", "ArbitrageExecuted", "TradeBlocked"].includes(ev.name)) tb.add(l.blockNumber);
  for (const b of tb) await provider.getBlock(b);
  provider.destroy();
  const out = { block: latest, at: new Date().toISOString(), rpc: D.rpc, cache };
  fs.writeFileSync(path.join(ROOT, "dashboard/snapshot.json"), JSON.stringify(out));
  return { block: latest, entries: Object.keys(cache).length, kinds: [...new Set(acts.map((a) => KIND(a.ev.name)))] };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  console.log(JSON.stringify(await writeSnapshot()));
  process.exit(0);
}
