-- crypto_alert_t: Phase 1 pipeline
--
-- Prerequisites: Fetch prices first (outside Nix sandbox — needs network):
--   python scripts/fetch_prices.py
--
-- Architecture: T (read CSV) -> rn (analyse) -> pyn (alert) -> Quarto (report)
-- Nix sandbox has no network access, so data fetch is a pre-step.

p = pipeline {

  -- 1. T: read pre-fetched prices CSV
  --    Written by scripts/fetch_prices.py (run before `t run`)
  prices = node(
    command = read_csv("data/latest_prices.csv", separator = "|"),
    serializer = ^arrow
  )

  -- 1b. T: read accumulated price history (appended by fetch_prices.py)
  history = node(
    command = read_csv("data/price_history.csv", separator = "|"),
    serializer = ^arrow
  )

  -- 2. R: analyse prices with dplyr
  --    Receives `prices` as Arrow table (auto-deserialized)
  --    Computes summary stats and simple alert triggers
  analysis = rn(
    command = <{
      library(dplyr)

      analysis <- prices |>
        mutate(
          is_stablecoin = token %in% c("USDC", "USDT"),
          depeg_alert = is_stablecoin & abs(price_usd - 1.0) > 0.005,
          trigger_alert = depeg_alert
        )
    }>,
    deserializer = ^arrow,
    serializer = ^arrow
  )

  -- 3. Python: format alerts (plain text for Phase 1, Swarms agent in Phase 2)
  alerts = pyn(
    command = <{
import pandas as pd
from datetime import datetime, timezone

triggered = analysis[analysis["trigger_alert"] == True]

if len(triggered) > 0:
    lines = ["ALERT at " + datetime.now(timezone.utc).strftime("%H:%M UTC") + ":"]
    for _, row in triggered.iterrows():
        line = "  {}: USD {:.4f} (depeg: {:.4f})".format(
            row["token"], row["price_usd"], abs(row["price_usd"] - 1.0)
        )
        lines.append(line)
    alerts = "\n".join(lines)
else:
    alerts = "No alerts at " + datetime.now(timezone.utc).strftime("%H:%M UTC") + ". All stable."
    }>,
    deserializer = ^arrow,
    serializer = ^json
  )

  -- 4. Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()
