#!/usr/bin/env bash
# Fetch prices (needs network) then run T pipeline (sandboxed) then show results
set -euo pipefail

echo ">>> Fetching token prices..."
python3 scripts/fetch_prices.py

echo ""
echo ">>> Fetching NFT floor prices..."
python3 scripts/fetch_nft_floors.py

echo ""
echo ">>> Running T pipeline..."
t run src/pipeline.t

echo ""
echo ">>> Results:"
echo "--- Prices ---"
cat data/latest_prices.csv
echo ""
echo "--- Alerts ---"
cat pipeline-output/alerts/artifact
echo ""

if [ -f pipeline-output/report/artifact/report.html ]; then
  echo "--- Report ---"
  echo "Open: pipeline-output/report/artifact/report.html"
fi

echo ""
echo ">>> Swarms agent post-step (dry run)..."
python3 scripts/swarms_agent.py
