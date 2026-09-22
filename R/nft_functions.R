# Pure R functions for NFT floor-price anomaly detection (issue #9).
#
# Deliberately kept in a SEPARATE file from R/analysis_functions.R, and
# deliberately named without the substring "analysis":
#
#   T's node-dependency inference appears to substring-match a node's
#   `include` paths against every OTHER node's name. Any node whose include
#   list names a file containing the literal text "analysis" (e.g.
#   "R/analysis_functions.R") is wrongly treated as depending on the sibling
#   T node literally called `analysis`, and T then tries to readRDS() that
#   node's arrow-serialized artifact -- `readRDS(".../analysis/artifact") :
#   read error`. Reproduced directly: a standalone `nft_analysis` rn node
#   including "R/analysis_functions.R" failed this way; splitting the NFT
#   functions into this file (no "analysis" substring in path or node name)
#   and sourcing it directly (no _targets.R/tar_make() needed for this small,
#   7-collection computation) avoids the collision. See src/pipeline.t's
#   `nft_alerts` node.
#
# Sourced by both:
#   - _targets.R (tar_source(), inside the `analysis` rn node's targets run
#     -- crew-parallel path, alongside the token targets)
#   - src/pipeline.t's `nft_alerts` node (plain source(), no targets/crew --
#     unnecessary overhead for 7 collections)
#
# No global state, no side effects outside return values -- same discipline
# as R/analysis_functions.R.

suppressPackageStartupMessages({
  library(dplyr)
})

# Same robust MAD z-score pattern as R/analysis_functions.R's
# compute_alerts()::price_anomaly, applied to scripts/fetch_nft_floors.py's
# output (data/nft_floor_history.parquet). A longer window than the 7d token
# default: per docs/REGIME_DETECTION_PLAN.md "Caveats", NFT floors are
# noisier than token prices.
NFT_WINDOW_DAYS  <- 14
NFT_MIN_OBS      <- 10    # same MIN_OBS_ROBUST gate as compute_alerts()
NFT_MIN_REL_MAD  <- 0.005 # same MIN_REL_MAD gate as compute_alerts()
NFT_Z_FLOOR_DROP <- 3.0   # same Z_PRICE_ALERT threshold as compute_alerts()

#' Parse fetched_at to POSIXct and sort. Mirrors prepare_history().
prepare_nft_history <- function(nft_hist_df) {
  nft_hist_df |>
    mutate(fetched_at = as.POSIXct(fetched_at, tz = "UTC")) |>
    arrange(collection, fetched_at)
}

#' Rolling median/MAD of floor_sol per collection, time-based window.
#' Mirrors compute_window_summary() but on `collection` instead of `token`,
#' and on floor_sol (there is no direct USD floor -- SOL-denominated per the
#' Magic Eden API, per the fetcher's own docstring).
compute_nft_window_summary <- function(nft_hist, window_days = NFT_WINDOW_DAYS) {
  ref_time <- if (nrow(nft_hist) > 0) max(nft_hist$fetched_at) else Sys.time()
  cutoff <- ref_time - as.difftime(window_days, units = "days")

  nft_hist |>
    filter(fetched_at >= cutoff) |>
    group_by(collection) |>
    summarise(
      floor_median_14d = median(floor_sol, na.rm = TRUE),
      floor_mad_14d    = mad(floor_sol, na.rm = TRUE),
      n_14d            = n(),
      .groups = "drop"
    )
}

#' Latest snapshot row per collection.
nft_latest_snapshot <- function(nft_hist) {
  nft_hist |>
    group_by(collection) |>
    slice_max(fetched_at, n = 1, with_ties = FALSE) |>
    ungroup()
}

#' Combine latest floor with the rolling summary into a per-collection alert
#' table. Same gates as compute_alerts()'s price_anomaly: minimum observation
#' count AND non-trivial relative MAD (excludes near-flat windows), so a
#' floor that hasn't moved doesn't produce a divide-by-near-zero z-score.
compute_nft_alerts <- function(nft_latest, nft_summary) {
  nft_latest |>
    left_join(nft_summary, by = "collection") |>
    mutate(
      have_robust_history = !is.na(n_14d) & n_14d >= NFT_MIN_OBS,
      rel_mad_14d = if_else(
        !is.na(floor_median_14d) & floor_median_14d > 0 & !is.na(floor_mad_14d),
        floor_mad_14d / abs(floor_median_14d),
        NA_real_
      ),
      nontrivial_mad = !is.na(rel_mad_14d) & rel_mad_14d >= NFT_MIN_REL_MAD,

      floor_zscore = if_else(
        have_robust_history & nontrivial_mad & floor_mad_14d > 0,
        (floor_median_14d - floor_sol) / floor_mad_14d,
        NA_real_
      ),
      # Only a DROP counts (a floor spike isn't the risk this exists to flag).
      floor_drop_alert = !is.na(floor_zscore) & floor_zscore > NFT_Z_FLOOR_DROP
    ) |>
    select(
      collection, slug, floor_sol, listed_count, fetched_at,
      floor_median_14d, floor_mad_14d, n_14d,
      have_robust_history, nontrivial_mad, floor_zscore, floor_drop_alert
    )
}
