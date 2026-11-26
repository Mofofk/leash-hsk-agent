#!/usr/bin/env bash
# One-command quickstart: build + test the contracts, then serve the read-only dashboard.
# Needs Foundry and Python 3 (or any static server). No keys needed for this.
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d contracts/lib/forge-std ]; then
  (cd contracts && forge install foundry-rs/forge-std --no-git)
fi
(cd contracts && forge build && forge test)
echo
echo "Dashboard (reads HSK Chain testnet directly): http://localhost:8080/dashboard/"
python3 -m http.server 8080
