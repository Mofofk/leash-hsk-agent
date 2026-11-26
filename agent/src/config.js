import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

// minimal .env loader (no dependency); real env vars win
function loadEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2];
  }
}
loadEnv(path.join(ROOT, ".env"));

const NETWORK = process.env.LEASH_NETWORK || "hsk-testnet";
const all = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments.json"), "utf8"));
export const net = all[NETWORK];
export const mainnetRef = all["hsk-mainnet (prepared, not deployed)"];
export const VAULT_ABI = JSON.parse(fs.readFileSync(path.join(ROOT, "agent/abi/LeashVault.json"), "utf8"));
export const DECISIONS_DIR = path.join(ROOT, "decisions");
export const STATE_FILE = path.join(ROOT, "agent/state.json");
export const PORT = Number(process.env.PORT || 8787);

export const BLOCK_CODES = [
  "NONE", "PAUSED", "TOKEN_NOT_ALLOWED", "POOL_NOT_ALLOWED", "INSUFFICIENT_BALANCE", "COOLDOWN", "FREQUENCY",
  "ORACLE", "PRICE_DEVIATION", "TRADE_TOO_LARGE", "POSITION_LIMIT", "DAILY_LOSS_LIMIT", "STOP_LOSS_ACTIVE",
  "SLIPPAGE", "ARB_UNPROFITABLE", "ORACLE_DEVIATION", "STABLE_DEPEG",
];

export const DEFAULT_PREFS = {
  riskAppetite: "balanced", // conservative | balanced | aggressive
  targetWhskPct: 50, // target share of NAV held in WHSK
  rebalanceBandPct: 10, // only rebalance when off target by more than this
  arbMinEdgeBps: 40, // only take fee-tier arbitrage when the quoted round trip beats this
  loopSeconds: 120,
  assets: ["WHSK", "USDT"],
};

export function loadPrefs() {
  try {
    return { ...DEFAULT_PREFS, ...JSON.parse(fs.readFileSync(STATE_FILE, "utf8")) };
  } catch {
    return { ...DEFAULT_PREFS };
  }
}
export function savePrefs(p) {
  fs.writeFileSync(STATE_FILE, JSON.stringify(p, null, 2));
}
