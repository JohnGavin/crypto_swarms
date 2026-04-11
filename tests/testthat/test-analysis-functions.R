# Tests for R/analysis_functions.R
# Snapshot ratio target: ≥30% of test_that blocks use expect_snapshot()

source("../../R/analysis_functions.R")

# ---- Synthetic test fixtures ----

make_prices <- function(n = 3) {
  tibble::tibble(
    token = c("SOL", "USDC", "USDT")[seq_len(n)],
    source = "test",
    price_usd = c(80.0, 1.0001, 0.9999)[seq_len(n)],
    price_change_24h = c(2.5, -0.01, 0.005)[seq_len(n)],
    liquidity = c(6e8, 4e8, 3e7)[seq_len(n)],
    block_id = 1:n,
    fetched_at = as.POSIXct(Sys.time(), tz = "UTC")
  )
}

make_history <- function(n_days = 30, tokens = c("SOL", "USDC")) {
  dates <- seq(Sys.time() - as.difftime(n_days, units = "days"), Sys.time(), by = "1 day")
  rows <- list()
  set.seed(42)
  for (tok in tokens) {
    base_price <- if (tok == "SOL") 80 else 1.0
    base_liq   <- if (tok == "SOL") 6e8 else 4e8
    rows[[tok]] <- tibble::tibble(
      token = tok,
      source = "test",
      price_usd = base_price * (1 + cumsum(rnorm(length(dates), 0, 0.02))),
      price_change_24h = rnorm(length(dates), 0, 1),
      liquidity = base_liq * (1 + cumsum(rnorm(length(dates), 0, 0.005))),
      block_id = seq_along(dates),
      fetched_at = dates
    )
  }
  dplyr::bind_rows(rows)
}

# ---- Tests: validate_prices ----

test_that("validate_prices passes on good data", {
  prices <- make_prices(3)
  result <- validate_prices(prices)
  expect_identical(result, prices)
})

test_that("validate_prices fails on missing column", {
  bad <- make_prices(3) |> dplyr::select(-price_usd)
  expect_error(validate_prices(bad), "pointblank")
})

# SNAPSHOT: validation of negative prices triggers error
test_that("validate_prices rejects negative prices", {
  bad <- make_prices(3) |> dplyr::mutate(price_usd = -1)
  expect_error(validate_prices(bad), "pointblank")
})

# ---- Tests: prepare_history ----

test_that("prepare_history converts fetched_at to POSIXct and sorts", {
  hist <- make_history(10)
  result <- prepare_history(hist)
  expect_s3_class(result$fetched_at, "POSIXct")
  # Sorted within each token
  for (tok in unique(result$token)) {
    sub <- result[result$token == tok, ]
    expect_true(all(diff(sub$fetched_at) >= 0))
  }
})

# ---- Tests: compute_window_summary ----

test_that("compute_window_summary returns expected columns", {
  hist <- prepare_history(make_history(30))
  result <- compute_window_summary(hist, 7, "7d")
  expected_cols <- c("token", "ma_7d", "median_7d", "mad_7d",
                     "liq_median_7d", "liq_mad_7d", "n_liq_7d", "n_7d")
  expect_true(all(expected_cols %in% names(result)))
})

# SNAPSHOT: column names from 7d summary
test_that("compute_window_summary column names snapshot", {
  hist <- prepare_history(make_history(30))
  result <- compute_window_summary(hist, 7, "7d")
  expect_snapshot(names(result))
})

test_that("compute_window_summary uses time-based window (not count)", {
  hist <- prepare_history(make_history(30))
  result_7d  <- compute_window_summary(hist, 7,  "7d")
  result_30d <- compute_window_summary(hist, 30, "30d")
  # 30d window should have more observations than 7d
  expect_true(all(result_30d$n_30d >= result_7d$n_7d))
})

# ---- Tests: compute_bollinger ----

test_that("compute_bollinger returns valid band columns", {
  hist <- prepare_history(make_history(30))
  summary_7d <- compute_window_summary(hist, 7, "7d")
  bb <- compute_bollinger(summary_7d, "7d")
  expect_true(all(c("bb_mid_7d", "bb_upper_7d", "bb_lower_7d", "bb_valid_7d") %in% names(bb)))
  # Upper must be >= mid >= lower
  expect_true(all(bb$bb_upper_7d >= bb$bb_mid_7d, na.rm = TRUE))
  expect_true(all(bb$bb_mid_7d >= bb$bb_lower_7d, na.rm = TRUE))
})

# SNAPSHOT: Bollinger band structure
test_that("compute_bollinger output structure snapshot", {
  hist <- prepare_history(make_history(30))
  summary_7d <- compute_window_summary(hist, 7, "7d")
  bb <- compute_bollinger(summary_7d, "7d")
  expect_snapshot(str(bb))
})

# ---- Tests: compute_alerts ----

test_that("compute_alerts detects stablecoin depeg", {
  prices <- make_prices(3) |> dplyr::mutate(
    price_usd = dplyr::if_else(token == "USDC", 0.990, price_usd)
  )
  hist <- prepare_history(make_history(30))
  s7  <- compute_window_summary(hist, 7,  "7d")
  s30 <- compute_window_summary(hist, 30, "30d")
  bb  <- compute_bollinger(s7, "7d")
  result <- compute_alerts(prices, s7, s30, bb)

  usdc <- result[result$token == "USDC", ]
  expect_true(usdc$depeg_alert)
  expect_true(usdc$trigger_alert)
})

test_that("compute_alerts no false positives on stable data", {
  prices <- make_prices(3)
  hist <- prepare_history(make_history(30))
  s7  <- compute_window_summary(hist, 7,  "7d")
  s30 <- compute_window_summary(hist, 30, "30d")
  bb  <- compute_bollinger(s7, "7d")
  result <- compute_alerts(prices, s7, s30, bb)

  # USDC at 1.0001 should NOT depeg
  usdc <- result[result$token == "USDC", ]
  expect_false(usdc$depeg_alert)
})

# SNAPSHOT: alert summary column names
test_that("compute_alerts column names snapshot", {
  prices <- make_prices(3)
  hist <- prepare_history(make_history(30))
  s7  <- compute_window_summary(hist, 7,  "7d")
  s30 <- compute_window_summary(hist, 30, "30d")
  bb  <- compute_bollinger(s7, "7d")
  result <- compute_alerts(prices, s7, s30, bb)
  expect_snapshot(names(result))
})

# ---- Tests: regime_rollmad ----

test_that("regime_rollmad excludes stablecoins", {
  hist <- prepare_history(make_history(60, tokens = c("SOL", "USDC")))
  result <- regime_rollmad(hist, window_days = 14, min_obs = 4)
  expect_true(!"USDC" %in% result$token)
  expect_true("SOL" %in% result$token)
})

test_that("regime_rollmad returns NA vol_mad with insufficient obs", {
  hist <- prepare_history(make_history(3, tokens = c("SOL")))
  result <- regime_rollmad(hist, window_days = 14, min_obs = 10)
  expect_true(all(is.na(result$vol_mad)))
})

test_that("regime_rollmad detects high-vol regime in synthetic spike", {
  set.seed(99)
  n_days <- 120
  dates <- seq(Sys.time() - as.difftime(n_days, units = "days"), Sys.time(), by = "1 day")
  n_dates <- length(dates)
  # low vol first half, high vol second half
  n_low <- floor(n_dates / 2)
  n_high <- n_dates - n_low - 1  # -1 for the initial price
  low_returns  <- rnorm(n_low, 0, 0.005)
  high_returns <- rnorm(n_high, 0, 0.05)
  prices <- 100 * cumprod(c(1, exp(c(low_returns, high_returns))))
  hist <- tibble::tibble(
    token = "TEST", source = "synthetic",
    price_usd = prices, price_change_24h = NA_real_,
    liquidity = NA_real_, block_id = NA_integer_,
    fetched_at = dates
  )
  result <- regime_rollmad(prepare_history(hist), window_days = 14, min_obs = 10)
  # Last 30 days should be mostly "high"
  last_30 <- result |> dplyr::filter(
    fetched_at >= max(fetched_at) - as.difftime(30, units = "days"),
    !is.na(regime_mad)
  )
  high_frac <- mean(last_30$regime_mad == "high")
  expect_gt(high_frac, 0.5)
})

# SNAPSHOT: regime labels for synthetic data
test_that("regime_rollmad label distribution snapshot", {
  set.seed(42)
  hist <- prepare_history(make_history(60, tokens = c("SOL")))
  result <- regime_rollmad(hist, window_days = 14, min_obs = 10)
  expect_snapshot(table(result$regime_mad, useNA = "ifany"))
})

# ---- Tests: regime_transitions ----

test_that("regime_transitions detects direction changes", {
  df <- tibble::tibble(
    token = rep("SOL", 5),
    fetched_at = seq(Sys.time() - as.difftime(4, units = "days"), Sys.time(), by = "1 day"),
    regime_mad = c("low", "low", "medium", "high", "high")
  )
  result <- regime_transitions(df)
  transitions <- result[result$is_transition == TRUE, ]
  expect_equal(nrow(transitions), 2)
  expect_equal(transitions$transition_direction, c("up", "up"))
})

# SNAPSHOT: transition output structure
test_that("regime_transitions output snapshot", {
  df <- tibble::tibble(
    token = rep("SOL", 4),
    fetched_at = seq(Sys.time() - as.difftime(3, units = "days"), Sys.time(), by = "1 day"),
    regime_mad = c("low", "high", "high", "low")
  )
  result <- regime_transitions(df)
  expect_snapshot(
    result |> dplyr::select(regime_mad, prev_regime, is_transition, transition_direction),
    transform = function(lines) gsub("202[0-9]-[0-9]{2}-[0-9]{2}", "DATE", lines)
  )
})

# ---- Tests: regime_latest ----

test_that("regime_latest returns one row per token", {
  df <- tibble::tibble(
    token = rep(c("SOL", "JUP"), each = 3),
    fetched_at = rep(seq(Sys.time() - as.difftime(2, units = "days"), Sys.time(), by = "1 day"), 2),
    regime_mad = c("low", "medium", "high", "high", "medium", "low"),
    is_transition = c(FALSE, TRUE, TRUE, FALSE, TRUE, TRUE),
    transition_direction = c(NA, "up", "up", NA, "down", "down")
  )
  result <- regime_latest(df)
  expect_equal(nrow(result), 2)
  expect_equal(sort(result$token), c("JUP", "SOL"))
})

# SNAPSHOT: regime_latest output
test_that("regime_latest snapshot", {
  df <- tibble::tibble(
    token = rep("SOL", 3),
    fetched_at = seq(Sys.time() - as.difftime(2, units = "days"), Sys.time(), by = "1 day"),
    regime_mad = c("low", "medium", "high"),
    is_transition = c(FALSE, TRUE, TRUE),
    transition_direction = c(NA, "up", "up")
  )
  expect_snapshot(regime_latest(df))
})
