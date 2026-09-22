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

  -- 1c. R: read accumulated NFT floor-price history from Parquet
  --    Written by scripts/fetch_nft_floors.py (issue #9). Analysed inside
  --    the same targets DAG as prices/history -- see nft_alert_summary in
  --    _targets.R.
  nft_history = rn(
    command = <{
      library(arrow)
      nft_history <- arrow::read_parquet("data/nft_floor_history.parquet")
    }>,
    include = ["data/nft_floor_history.parquet"],
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

      # Nix sandbox sets HOME=/homeless-shelter (read-only).
      # targets + crew need a writable HOME for metadata and worker tempfiles.
      if (!dir.exists(Sys.getenv("HOME"))) {
        tmp_home <- file.path(tempdir(), "home")
        dir.create(tmp_home, recursive = TRUE, showWarnings = FALSE)
        Sys.setenv(HOME = tmp_home)
      }

      arrow::write_parquet(prices,      "tmp_prices.parquet")
      arrow::write_parquet(history,     "tmp_history.parquet")
      arrow::write_parquet(nft_history, "tmp_nft_history.parquet")

      tar_make(reporter = "silent")
      analysis <- tar_read(alert_summary)
    }>,
    deserializer = [
      prices:      ^arrow,
      history:     ^arrow,
      nft_history: ^arrow
    ],
    include = [
      "_targets.R",
      "R/analysis_functions.R"
    ],
    serializer = ^arrow
  )

  -- 2b. R: NFT floor-price alert table (issue #9). A separate, lightweight
  --    node rather than a second target of `analysis`'s targets DAG: 7
  --    collections doesn't need crew parallelism, and (see R/nft_functions.R
  --    header) a node whose `include` names a file containing the substring
  --    "analysis" is wrongly wired as depending on the `analysis` node by
  --    T's node-dependency inference -- reproduced directly, worked around
  --    by keeping this node's only include free of that substring.
  nft_alerts = rn(
    command = <{
      library(dplyr)
      source("R/nft_functions.R")
      nft_prepped <- prepare_nft_history(nft_history)
      nft_summary <- compute_nft_window_summary(nft_prepped)
      nft_latest  <- nft_latest_snapshot(nft_prepped)
      nft_alerts  <- compute_nft_alerts(nft_latest, nft_summary)
    }>,
    deserializer = [
      nft_history: ^arrow
    ],
    include = [
      "R/nft_functions.R"
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
