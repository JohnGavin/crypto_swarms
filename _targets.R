# targets plan for the crypto_swarms analysis rn node.
#
# Runs INSIDE the Nix-sandboxed rn node. The enclosing rn command:
#   1. Writes `prices` and `history` (R objects from T) to parquet files
#   2. Calls tar_make()
#   3. Reads tar_read("alert_summary") as the node output
#
# Architecture notes:
#   - No cross-T-run caching: Nix sandbox creates a fresh build dir each run,
#     so `_targets/` meta store is ephemeral. The T content-addressed cache
#     is our cross-run cache instead.
#   - crew parallelism works within one build via local workers.
#   - Per-token pattern targets (see bollinger_7d) parallelize across workers.

library(targets)
library(crew)

tar_option_set(
  packages = c("dplyr", "arrow", "pointblank", "purrr"),
  controller = crew_controller_local(workers = 2L, seconds_wall = 3600),
  memory = "transient",
  garbage_collection = TRUE,
  format = "rds"
)

# Source pure R functions
tar_source("R/analysis_functions.R")

list(
  # --- Inputs (parquet files written by the rn node) ---
  tar_target(prices_file,  "tmp_prices.parquet",  format = "file"),
  tar_target(history_file, "tmp_history.parquet", format = "file"),

  tar_target(prices_raw,  arrow::read_parquet(prices_file)),
  tar_target(history_raw, arrow::read_parquet(history_file)),

  # --- Validation (fails pipeline on bad input) ---
  tar_target(prices_validated, validate_prices(prices_raw)),

  # --- History preparation ---
  tar_target(history_prepped, prepare_history(history_raw)),

  # --- Rolling summaries (run in parallel via crew) ---
  tar_target(summary_7d,  compute_window_summary(history_prepped, 7,  "7d")),
  tar_target(summary_30d, compute_window_summary(history_prepped, 30, "30d")),

  # --- Robust Bollinger bands ---
  tar_target(bollinger_7d, compute_bollinger(summary_7d, "7d")),

  # --- Regime detection (Phase R1: rolling MAD) ---
  tar_target(regime_rollmad_tbl, regime_rollmad(history_prepped, window_days = 14)),
  tar_target(regime_transitions_tbl, regime_transitions(regime_rollmad_tbl)),
  tar_target(regime_latest_tbl, regime_latest(regime_transitions_tbl)),

  # --- Final alert table ---
  tar_target(
    alert_summary,
    compute_alerts(prices_validated, summary_7d, summary_30d, bollinger_7d) |>
      dplyr::left_join(regime_latest_tbl, by = "token") |>
      dplyr::mutate(
        regime_shock = !is.na(is_transition) & is_transition &
                       transition_direction == "up",
        trigger_alert = trigger_alert | regime_shock
      )
  )
)
