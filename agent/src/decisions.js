import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";
import { DECISIONS_DIR } from "./config.js";

/// Writes the full reasoning as canonical JSON; returns keccak256 of the exact bytes (the on-chain reasonHash).
/// Anyone can re-hash decisions/<hash>.json and match it to the TradeExecuted/TradeBlocked/Decision event.
export function recordReason(obj) {
  const text = JSON.stringify(obj);
  const hash = ethers.keccak256(ethers.toUtf8Bytes(text));
  fs.mkdirSync(DECISIONS_DIR, { recursive: true });
  fs.writeFileSync(path.join(DECISIONS_DIR, `${hash}.json`), text);
  return hash;
}
