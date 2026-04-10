# Pure R functions for crypto_swarms analysis pipeline.
#
# Sourced by both:
#   - _targets.R (within the analysis rn node's targets run)
#   - Direct testing via Rscript for dev/debugging
#
# No global state, no side effects outside return values.
# Keep these pure so they're trivially testable and parallelizable by crew.

suppressPackageStartupMessages({
  library(dplyr)
  library(pointblank)
})

# NOTE: duckplyr is available in deps but NOT used inside the Nix sandbox rn node
# because DuckDB writes to HOME which is /homeless-shelter (read-only) in sandboxed
# builds. At current data volume (~6K rows) dplyr is fine.
# Re-evaluate when history exceeds ~100K rows (multiple years of 12h data).
USE_DUCKPLYR <- FALSE

# ---- Constants ----

# Robust anomaly thresholds. See ~/.claude/rules/robust-statistics.md and
# ~/.claude/rules/composite-alert-scoring.md for rationale.
MIN_OBS_ROBUST <- 10     # Minimum observations before computing MAD-based z-scores
MIN_REL_MAD    <- 0.005  # mad_7d / median_7d must exceed this (excludes near-flat windows)
Z_PRICE_ALERT  <- 3.0    # Robust z above this = price anomaly
Z_LIQ_DROP     <- 3.0    # Liquidity drop in MADs
LIQ_MIN_PCT    <- 0.50   # OR liquidity drop > 50% from median
DEPEG_THRESHOLD <- 0.005 # Stablecoin depeg threshold (0.5% from $1)
STABLECOINS    <- c("USDC", "USDT")

# Bollinger-band style threshold (robust version using MAD not SD)
BOLLINGER_K <- 3.0

# ---- Validation ----

#' Validate the latest prices snapshot with pointblank.
#' Fails loudly via stop() if any check fails.
#' @param prices_df data.frame with columns token, source, price_usd, ...
#' @return The input unchanged if validation passes, stops otherwise.
validate_prices <- function(prices_df) {
  agent <- create_agent(prices_df, tbl_name = "prices") |>
    col_exists(c("token", "source", "price_usd", "fetched_at",
                 "price_change_24h", "liquidity", "block_id")) |>
    col_is_character(c("token", "source", "fetched_at")) |>
    col_is_numeric(c("price_usd", "price_change_24h", "liquidity")) |>
    col_vals_not_null(c("token", "source", "price_usd", "fetched_at")) |>
    col_vals_gt(columns = "price_usd", value = 0) |>
    col_vals_lt(columns = "price_usd", value = 1e6) |>
    rows_distinct(columns = "token") |>
    interrogate()

  if (any(agent$validation_set$warn, na.rm = TRUE) ||
      any(agent$validation_set$stop, na.rm = TRUE)) {
    print(agent)
    stop("pointblank validation failed on `prices` table")
  }
  prices_df
}

# ---- History preparation ----

#' Parse fetched_at to POSIXct and return sorted history.
prepare_history <- function(history_df) {
  history_df |>
    mutate(fetched_at = as.POSIXct(fetched_at, tz = "UTC")) |>
    arrange(token, fetched_at)
}

# ---- Per-window summaries ----

#' Time-based rolling summary (MANDATORY time-based, NOT count-based).
#' @param hist data.frame with token, price_usd, liquidity, fetched_at (POSIXct)
#' @param window_days Integer window size in days
#' @param suffix Column name suffix, e.g. "7d"
compute_window_summary <- function(hist, window_days, suffix) {
  ref_time <- if (nrow(hist) > 0) max(hist$fetched_at) else Sys.time()
  cutoff <- ref_time - as.difftime(window_days, units = "days")

  hist |>
    filter(fetched_at >= cutoff) |>
    group_by(token) |>
    summarise(
      !!paste0("ma_",         suffix) := mean(price_usd, na.rm = TRUE),
      !!paste0("median_",     suffix) := median(price_usd, na.rm = TRUE),
      !!paste0("mad_",        suffix) := mad(price_usd, na.rm = TRUE),
      !!paste0("liq_median_", suffix) := median(liquidity, na.rm = TRUE),
      !!paste0("liq_mad_",    suffix) := mad(liquidity, na.rm = TRUE),
      !!paste0("n_liq_",      suffix) := sum(!is.na(liquidity)),
      !!paste0("n_",          suffix) := n(),
      .groups = "drop"
    )
}

# ---- Robust Bollinger bands (MAD-based) ----

#' Compute robust Bollinger bands from a window summary.
#' Middle = median, Upper/Lower = median +/- k * MAD.
compute_bollinger <- function(summary_df, suffix = "7d", k = BOLLINGER_K) {
  median_col <- paste0("median_", suffix)
  mad_col    <- paste0("mad_",    suffix)
  n_col      <- paste0("n_",      suffix)

  summary_df |>
    mutate(
      !!paste0("bb_mid_",   suffix) := .data[[median_col]],
      !!paste0("bb_upper_", suffix) := .data[[median_col]] + k * .data[[mad_col]],
      !!paste0("bb_lower_", suffix) := .data[[median_col]] - k * .data[[mad_col]],
      !!paste0("bb_valid_", suffix) := .data[[n_col]] >= MIN_OBS_ROBUST
    ) |>
    select(token, starts_with("bb_"))
}

# ---- Composite alert computation ----

#' Combine price + history summaries + Bollinger into the final alert table.
compute_alerts <- function(prices_df, summary_7d, summary_30d, bollinger_7d) {
  prices_df |>
    left_join(summary_7d,   by = "token") |>
    left_join(summary_30d,  by = "token") |>
    left_join(bollinger_7d, by = "token") |>
    mutate(
      have_robust_history = !is.na(n_7d) & n_7d >= MIN_OBS_ROBUST,

      rel_mad_7d = if_else(
        !is.na(median_7d) & median_7d > 0 & !is.na(mad_7d),
        mad_7d / abs(median_7d),
        NA_real_
      ),
      nontrivial_price_mad = !is.na(rel_mad_7d) & rel_mad_7d >= MIN_REL_MAD,

      # Price anomaly (robust MAD-based z-score with gates)
      robust_zscore = if_else(
        have_robust_history & nontrivial_price_mad & mad_7d > 0,
        abs(price_usd - median_7d) / mad_7d,
        NA_real_
      ),
      price_anomaly = !is.na(robust_zscore) & robust_zscore > Z_PRICE_ALERT,

      # Bollinger band break (uses robust bands)
      bb_break = !is.na(bb_valid_7d) & bb_valid_7d & (
        (!is.na(bb_upper_7d) & price_usd > bb_upper_7d) |
        (!is.na(bb_lower_7d) & price_usd < bb_lower_7d)
      ),

      # Liquidity drop: need enough non-NA liquidity observations AND non-trivial
      # relative MAD. CoinGecko backfill has NA liquidity so until we accumulate
      # enough live Jupiter observations, the MAD-based gate stays closed.
      have_robust_liq = !is.na(n_liq_7d) & n_liq_7d >= MIN_OBS_ROBUST,
      rel_liq_mad_7d = if_else(
        !is.na(liq_median_7d) & liq_median_7d > 0 & !is.na(liq_mad_7d),
        liq_mad_7d / abs(liq_median_7d),
        NA_real_
      ),
      nontrivial_liq_mad = !is.na(rel_liq_mad_7d) & rel_liq_mad_7d >= MIN_REL_MAD,

      liq_zscore = if_else(
        have_robust_liq & nontrivial_liq_mad & liq_mad_7d > 0,
        (liq_median_7d - liquidity) / liq_mad_7d,
        NA_real_
      ),
      liq_drop_pct = if_else(
        !is.na(liq_median_7d) & liq_median_7d > 0,
        (liq_median_7d - liquidity) / liq_median_7d,
        NA_real_
      ),
      liquidity_alert = (
        (!is.na(liq_zscore)   & liq_zscore   > Z_LIQ_DROP) |
        (!is.na(liq_drop_pct) & liq_drop_pct > LIQ_MIN_PCT)
      ),

      # Depeg check
      is_stablecoin = token %in% STABLECOINS,
      depeg_alert   = is_stablecoin & abs(price_usd - 1.0) > DEPEG_THRESHOLD,

      # Combined trigger (regime_shock wired later after regime targets exist)
      trigger_alert = depeg_alert | price_anomaly | bb_break | liquidity_alert
    )
}

# ---- Regime Detection (Phase R1: Rolling MAD) ----

#' Compute rolling MAD of log returns per token with time-based window.
#' Classifies into tertiles: low (bottom 33%), medium, high (top 33%).
#' Returns one row per (token, fetched_at) with regime label.
#'
#' @param hist data.frame with token, price_usd, fetched_at (POSIXct), sorted
#' @param window_days Rolling window size in days (default 14)
#' @param min_obs Minimum observations in window before computing (default 10)
#' @return data.frame with columns: token, fetched_at, log_return, vol_mad,
#'   regime_mad (low/medium/high)
regime_rollmad <- function(hist, window_days = 14, min_obs = 10) {
  # Exclude stablecoins — their volatility is trivially zero
  hist <- hist |> filter(!(token %in% STABLECOINS))

  if (nrow(hist) == 0) {
    return(tibble::tibble(
      token = character(), fetched_at = as.POSIXct(character()),
      log_return = numeric(), vol_mad = numeric(), regime_mad = character()
    ))
  }

  hist |>
    group_by(token) |>
    arrange(fetched_at, .by_group = TRUE) |>
    mutate(
      log_return = c(NA_real_, diff(log(price_usd)))
    ) |>
    # Time-based rolling MAD (not count-based, per data-validation-timeseries rule)
    mutate(
      vol_mad = purrr::map_dbl(
        seq_along(fetched_at),
        function(i) {
          cutoff <- fetched_at[i] - as.difftime(window_days, units = "days")
          window_returns <- log_return[fetched_at >= cutoff & fetched_at <= fetched_at[i]]
          window_returns <- window_returns[!is.na(window_returns)]
          if (length(window_returns) < min_obs) return(NA_real_)
          mad(window_returns, na.rm = TRUE)
        }
      )
    ) |>
    # Per-token tertile classification (across full history for that token)
    mutate(
      q33 = quantile(vol_mad, 0.33, na.rm = TRUE),
      q67 = quantile(vol_mad, 0.67, na.rm = TRUE),
      regime_mad = case_when(
        is.na(vol_mad)    ~ NA_character_,
        vol_mad <= q33    ~ "low",
        vol_mad >= q67    ~ "high",
        TRUE              ~ "medium"
      )
    ) |>
    ungroup() |>
    select(token, fetched_at, log_return, vol_mad, regime_mad)
}

#' Detect regime transitions from a regime series.
#' A transition is when regime_consensus changes between consecutive observations.
#'
#' @param regime_df data.frame with token, fetched_at, regime_mad (or regime_consensus)
#' @param regime_col Name of the regime column (default "regime_mad")
#' @return data.frame with added columns: prev_regime, is_transition, transition_direction
regime_transitions <- function(regime_df, regime_col = "regime_mad") {
  regime_df |>
    group_by(token) |>
    arrange(fetched_at, .by_group = TRUE) |>
    mutate(
      prev_regime = lag(.data[[regime_col]]),
      is_transition = !is.na(prev_regime) &
                      !is.na(.data[[regime_col]]) &
                      prev_regime != .data[[regime_col]],
      transition_direction = case_when(
        !is_transition ~ NA_character_,
        prev_regime == "low"    & .data[[regime_col]] %in% c("medium", "high") ~ "up",
        prev_regime == "medium" & .data[[regime_col]] == "high"                ~ "up",
        prev_regime == "high"   & .data[[regime_col]] %in% c("medium", "low")  ~ "down",
        prev_regime == "medium" & .data[[regime_col]] == "low"                 ~ "down",
        TRUE ~ "lateral"
      )
    ) |>
    ungroup()
}

#' Get the latest regime + transition per token.
#' @return data.frame: token, regime_mad, transition_direction (NA if no recent transition)
regime_latest <- function(regime_with_transitions) {
  regime_with_transitions |>
    group_by(token) |>
    slice_max(fetched_at, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(token, regime_mad, is_transition, transition_direction)
}
