-- crypto_alert_t: Phase 2 pipeline (targets + crew inside rn)
--
-- Prerequisites: Fetch prices first (outside Nix sandbox — needs network):
--   python scripts/fetch_prices.py
--
-- Data format: Parquet (was CSV in Phase 1)
--   data/latest_prices.parquet   — latest snapshot, overwritten each run
--   data/price_history.parquet   — accumulated, appended + deduped each run
--
-- Architecture: include parquet -> rn (targets DAG) -> pyn (alert) -> Quarto

p = pipeline {

  -- 1a. R: read latest prices snapshot from Parquet
  prices = rn(
    command = <{
      library(arrow)
      prices <- arrow::read_parquet("data/latest_prices.parquet")
    }>,
    include = ["data/latest_prices.parquet"],
    serializer = ^arrow
  )

  -- 1b. R: read accumulated price history from Parquet
  history = rn(
    command = <{
      library(arrow)
      history <- arrow::read_parquet("data/price_history.parquet")
    }>,
    include = ["data/price_history.parquet"],
    serializer = ^arrow
  )

  -- 2. R: analyse prices via targets + crew DAG (Phase 2)
  --    Inside the rn node:
  --      (a) Write the deserialized prices/history tables to parquet files
  --      (b) Run the targets DAG via tar_make() with crew parallelism
  --      (c) Read the alert_summary target as this node's output
  --
  --    See _targets.R for the plan and R/analysis_functions.R for pure helpers.
  analysis = rn(
    command = <{
      library(arrow)
      library(targets)

      arrow::write_parquet(prices,  "tmp_prices.parquet")
      arrow::write_parquet(history, "tmp_history.parquet")

      tar_make(reporter = "silent")
      analysis <- tar_read(alert_summary)
    }>,
    deserializer = [
      prices:  ^arrow,
      history: ^arrow
    ],
    include = [
      "_targets.R",
      "R/analysis_functions.R"
    ],
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
