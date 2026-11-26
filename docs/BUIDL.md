# DoraHacks BUIDL write-up: Leash (draft, not submitted)

**Name:** Leash

**Tagline:** An AI trading agent for HSKSwap whose risk limits live in a smart contract the AI cannot override.

**Track:** Track 1: AI Agent Trading (HSK Chain Horizon Hackathon · Seoul)

**Links**
- GitHub: https://github.com/Mofofk/leash-hsk-agent (private until approved for publishing)
- Dashboard (static, reads the chain): https://raw.githack.com/Mofofk/leash-hsk-agent/main/dashboard/index.html (works once the repo is public)
- Demo video: docs/Leash_HSK_demo.mp4 (upload to YouTube/X and paste the link)
- Vault (HSK testnet, verified): https://testnet-explorer.hskchain.net/address/0x998F3EAA037d74F328F4Fc300DB6C3C6bBB1951A

---

## Description

AI agents can now trade by themselves. One bad prompt, one hallucination, or one leaked agent key, and the wallet is gone. **Leash** keeps the AI useful and puts the money behind rules it can't break.

**How it works**
1. Your funds sit in **LeashVault** on HSK Chain. The agent has its own key, and that key can do exactly one thing: ask the vault to trade on **HSKSwap**. Output always comes back to the vault. Only you can withdraw.
2. The vault checks every request on-chain:
   - allow-listed tokens and HSKSwap pools
   - max trade and max position, valued at the pool **TWAP** (from `observe()`), not the spot price someone can push around
   - a slippage floor against the TWAP, which overrides whatever minimum the agent asked for
   - a spot-vs-TWAP manipulation guard
   - cooldown and trades per day
   - a daily loss breaker (after it trips, only de-risking trades are allowed)
   - a stop-loss **anyone** can enforce
   - an **APRO** oracle cross-check and USDT depeg guard on mainnet
   - your kill switch
   - hard caps that even you can't exceed
3. **Refusals are on-chain events, not silent reverts.** Every trade, block and hold carries a `reasonHash`. The agent's full reasoning is published as JSON, and the dashboard re-hashes it to prove it matches the chain.
4. **Tightening is instant, loosening is timelocked.** We found this the honest way. On our v2 vault, the chat model "helpfully" raised the trade limit to fit an oversized sell order. v3 queues every loosening behind an on-chain timelock (10 min on testnet, 1 h on mainnet) that the owner can cancel. A hijacked prompt can't widen the leash.

**The agent.** It reads both HSKSwap WHSK/USDT fee tiers (spot, 5- and 30-minute TWAP, liquidity, spread) and quotes the exact round trip through HSKSwap **QuoterV2**. It builds rule-based candidates (atomic cross-fee-tier arbitrage, rebalancing toward your target, momentum) and pre-flights each one against the vault. **Gemini** then picks one or holds, and explains why. Arbitrage is **atomic**: if the round trip doesn't come back with profit, the whole thing reverts and is logged as `ARB_UNPROFITABLE`. For reference it also tracks real HSK prices across mainnet HSKSwap, **HashKey Global** and **APRO**.

**Chat.** You talk to it in plain words: "be conservative, max 0.5 USDT a trade, 5% stop-loss", "trade at most 10 times a day", "what's my P&L?", "pause". Gemini turns that into on-chain parameter updates, and your sentence is stored on-chain with the change.

**Dashboard.** NAV, realized and unrealized P&L, positions with cost basis, live limits, queued loosenings, market signals, and an on-chain decision log with verified reasoning. You can connect a wallet; the owner gets the kill switch.

**Proof on HSK testnet (real transactions)**
- Trade executed: https://testnet-explorer.hskchain.net/tx/0x425e25eed1e3e69df8dd50c813a591b060285ddc60768d9752f52150057c1e16
- Atomic arbitrage: https://testnet-explorer.hskchain.net/tx/0x2774bc3ea9588b946ebd8dd0bdeccdf7b8ed13097698736f89caab4bf6bb6e07
- Trade blocked on-chain (TRADE_TOO_LARGE): https://testnet-explorer.hskchain.net/tx/0x269ad66d985ffb13ee9ba44f1236de3ccff77870587f7bc7a2d25b1037e6211b
- Limits tightened from chat: https://testnet-explorer.hskchain.net/tx/0x9ce7272dc67a74d4b99f3e4af19e46f305e7b8b079e8450f27159885a8270a0a
- Loosening timelocked: https://testnet-explorer.hskchain.net/tx/0x22a53cc4009173d5c85f291a3a22bf797847e4c82877d8482f32b67758777e22
- Kill switch: https://testnet-explorer.hskchain.net/tx/0xe7cf5fc7fada41bdb94d6efde0eebcb693742dfcb888cfe939159bc0949daa4d

**Technical maturity**
- 34 Foundry tests. 33 run on a fork of the live HSK testnet HSKSwap pools: stop-loss, daily loss breaker, kill switch, manipulation guard, oracle and depeg guards, timelock, arbitrage, and a TWAP-floor fuzz test. The last one is a mainnet dry run against the real APRO feeds.
- The contract is verified on HSK Blockscout.
- The mainnet deploy script is ready (chain 177, APRO wired in, 1-hour loosening timelock).

**Officially recommended products used:** HSKSwap (SwapRouter02, QuoterV2, V3 pools, factory, `@hskswap/sdk-core` addresses), HSK Chain testnet and faucet, HSK Blockscout verification, the APRO oracle (listed in the HSK Chain docs), HashKey Global market data. The owner can be a Safe.

**Honest notes:** Testnet pool prices are synthetic (WHSK is about 78 USDT on one tier and 54 on the other), so we claim no market profit. The code is not audited. The demo server signs limit changes with the owner key; in production the user's own wallet signs them.

**Team:** Ajay Kumar, India · X @coolajay0099 · Telegram Coolboi0099
