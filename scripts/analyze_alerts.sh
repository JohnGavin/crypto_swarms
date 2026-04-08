#!/usr/bin/env bash
# Gather context for Claude Code to analyze pending crypto alerts.
#
# Two modes:
#   1. Manual: open Claude Code, say "run scripts/analyze_alerts.sh and
#      summarize findings". Uses your Max subscription interactively.
#   2. Scheduled: wire into the /schedule skill to run every N hours.
#
# Writes a structured markdown report to /tmp/crypto_analysis_context.md
# which the agent reads and summarizes.
set -euo pipefail

OUT=/tmp/crypto_analysis_context.md

{
  echo "# Crypto Swarms — Analysis Context"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  echo "## Latest prices"
  echo ""
  echo '```'
  cat data/latest_prices.csv 2>/dev/null || echo "(no latest_prices.csv — run fetch_prices.py)"
  echo '```'
  echo ""

  echo "## Alert status"
  echo ""
  echo '```'
  cat pipeline-output/alerts/artifact 2>/dev/null || echo "(no alerts artifact — run t run src/pipeline.t)"
  echo '```'
  echo ""

  echo "## Price history (last 20 rows)"
  echo ""
  echo '```'
  tail -20 data/price_history.csv 2>/dev/null || echo "(no history yet)"
  echo '```'
  echo ""

  echo "## Recent open alert issues on GitHub"
  echo ""
  gh issue list --repo JohnGavin/crypto_swarms --label alert --state open --limit 10 2>/dev/null || echo "(gh not available or no alerts)"
  echo ""

  echo "## Questions for the analyst"
  echo ""
  echo "1. Do the triggered alerts look like real depegs or data glitches?"
  echo "2. Is the 24h price change consistent with the current spot price?"
  echo "3. Should any open alert issues be closed as resolved?"
  echo "4. Are there patterns across tokens that suggest a broader event?"
} > "$OUT"

echo "Wrote analysis context to $OUT"
echo ""
echo "Next steps:"
echo "  Manual:    open Claude Code, say 'read $OUT and summarize'"
echo "  Scheduled: use /schedule skill with this script as the action"
