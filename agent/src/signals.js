import { ethers } from "ethers";
import { provider, POOL_ABI, quoter, T } from "./chain.js";
import { net, mainnetRef } from "./config.js";

const WHSK = T.WHSK.address;
const USDT = T.USDT.address;

// price of WHSK in USDT from a tick (decimals-aware)
function whskPriceFromTick(tick, token0, d0 = 18, d1 = 18) {
  const raw = Math.pow(1.0001, Number(tick)); // token1 per token0
  const t1PerT0 = raw * Math.pow(10, d0 - d1);
  return token0.toLowerCase() === WHSK.toLowerCase() ? t1PerT0 : 1 / t1PerT0;
}

async function twapTick(pool, secs) {
  try {
    const [cum] = await pool.observe([secs, 0]);
    const d = cum[1] - cum[0];
    let t = d / BigInt(secs);
    if (d < 0n && d % BigInt(secs) !== 0n) t -= 1n;
    return Number(t);
  } catch {
    return null;
  }
}

export async function readPool(name, { address, fee }) {
  const pool = new ethers.Contract(address, POOL_ABI, provider);
  const [s0, liq, token0, tw5, tw30] = await Promise.all([
    pool.slot0(), pool.liquidity(), pool.token0(), twapTick(pool, 300), twapTick(pool, 1800),
  ]);
  const spot = whskPriceFromTick(s0.tick, token0);
  return {
    name, address, fee: Number(fee), liquidity: liq.toString(), spotTick: Number(s0.tick),
    spot,
    twap5m: tw5 === null ? null : whskPriceFromTick(tw5, token0),
    twap30m: tw30 === null ? null : whskPriceFromTick(tw30, token0),
    deviationBps: tw5 === null ? null : Math.abs(Number(s0.tick) - tw5),
  };
}

async function quote(tokenIn, tokenOut, fee, amountIn) {
  try {
    const r = await quoter.quoteExactInputSingle.staticCall({ tokenIn, tokenOut, amountIn, fee, sqrtPriceLimitX96: 0 });
    return r.amountOut;
  } catch {
    return 0n;
  }
}

/// Executable round-trip edge across two fee tiers, from the official HSKSwap QuoterV2, for a given WHSK size.
export async function arbEdge(sellFee, buyFee, sizeWei) {
  const mid = await quote(WHSK, USDT, sellFee, sizeWei);
  if (mid === 0n) return { sellFee, buyFee, edgeBps: -1e9 };
  const back = await quote(USDT, WHSK, buyFee, mid);
  const edgeBps = Number(((back - sizeWei) * 10000n) / sizeWei);
  return { sellFee, buyFee, size: ethers.formatEther(sizeWei), usdtMid: ethers.formatEther(mid), whskBack: ethers.formatEther(back), edgeBps };
}

export async function cexPrice() {
  try {
    const r = await fetch("https://api-glb.hashkey.com/quote/v1/ticker/24hr?symbol=HSKUSDT", { signal: AbortSignal.timeout(6000) });
    const [t] = await r.json();
    return { source: "HashKey Global HSKUSDT (CEX, mainnet market)", last: Number(t.c), bid: Number(t.b), ask: Number(t.a) };
  } catch {
    return null;
  }
}

/// Real HSK price on HSKSwap mainnet (read only), for reference next to the CEX price.
export async function mainnetDexPrice() {
  try {
    const p = new ethers.JsonRpcProvider(mainnetRef.rpc, 177, { staticNetwork: true });
    const [name, info] = Object.entries(mainnetRef.pools)[0];
    const pool = new ethers.Contract(info.address, POOL_ABI, p);
    const [s0, token0] = await Promise.all([pool.slot0(), pool.token0()]);
    const raw = Math.pow(1.0001, Number(s0.tick));
    const whsk = mainnetRef.tokens.WHSK.address.toLowerCase();
    // mainnet USDT has 6 decimals
    const price = token0.toLowerCase() === whsk ? raw * 1e12 : 1 / (raw * 1e12);
    let apro = null;
    try {
      const feed = new ethers.Contract(mainnetRef.apro["HSK/USD"], ["function latestRoundData() view returns (uint80,int256,uint256,uint256 updatedAt,uint80)"], p);
      const rd = await feed.latestRoundData();
      apro = { price: Number(rd[1]) / 1e8, updatedAt: Number(rd[3]) };
    } catch {}
    return { source: `HSKSwap mainnet ${name}`, price, aproHskUsd: apro };
  } catch {
    return null;
  }
}

export async function gatherSignals(sizeWei) {
  const entries = Object.entries(net.pools);
  const pools = await Promise.all(entries.map(([n, p]) => readPool(n, p)));
  const [a, b] = pools;
  const spreadBps = Math.round(((a.spot - b.spot) / Math.min(a.spot, b.spot)) * 10000);
  const [ab, ba, cex, mdex] = await Promise.all([
    arbEdge(a.fee, b.fee, sizeWei), arbEdge(b.fee, a.fee, sizeWei), cexPrice(), mainnetDexPrice(),
  ]);
  const ref = a; // 0.05% pool is the vault's valuation pool
  const momentumBps = ref.twap30m ? Math.round(((ref.spot - ref.twap30m) / ref.twap30m) * 10000) : 0;
  return {
    at: new Date().toISOString(),
    pools,
    feeTierSpreadBps: spreadBps,
    arbitrage: [ab, ba].sort((x, y) => y.edgeBps - x.edgeBps),
    momentumBps,
    reference: { cex, mainnetDex: mdex, note: "Testnet pool prices are synthetic; mainnet CEX/DEX prices are shown for context only." },
  };
}
