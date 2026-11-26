import { ethers } from "ethers";
import { net, VAULT_ABI } from "./config.js";

export const provider = new ethers.JsonRpcProvider(net.rpc, net.chainId, { staticNetwork: true });

export const POOL_ABI = [
  "function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16,uint16,uint16,uint8,bool)",
  "function observe(uint32[]) view returns (int56[] tickCumulatives,uint160[])",
  "function liquidity() view returns (uint128)",
  "function token0() view returns (address)",
  "function fee() view returns (uint24)",
];
export const QUOTER_ABI = [
  "function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96)) returns (uint256 amountOut,uint160,uint32,uint256)",
];
export const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function symbol() view returns (string)"];

export const agentWallet = process.env.AGENT_PK ? new ethers.Wallet(process.env.AGENT_PK, provider) : null;
// The owner key is the user's. In the demo the local server holds it so chat can sign parameter updates;
// in production the dashboard asks the user's own wallet to sign (see README).
export const ownerWallet = process.env.DEPLOYER_PK ? new ethers.Wallet(process.env.DEPLOYER_PK, provider) : null;

export const vaultRead = new ethers.Contract(net.vault, VAULT_ABI, provider);
export const vaultAsAgent = agentWallet ? vaultRead.connect(agentWallet) : null;
export const vaultAsOwner = ownerWallet ? vaultRead.connect(ownerWallet) : null;
export const quoter = new ethers.Contract(net.hskswap.quoterV2, QUOTER_ABI, provider);

export const T = Object.fromEntries(Object.entries(net.tokens).map(([s, t]) => [s, { symbol: s, ...t }]));
export const symbolOf = (addr) =>
  Object.values(T).find((t) => t.address.toLowerCase() === String(addr).toLowerCase())?.symbol || addr;
export const fmt = (x, d = 18, p = 6) => Number(ethers.formatUnits(x, d)).toFixed(p);
export const txUrl = (h) => `${net.explorer}/tx/${h}`;
