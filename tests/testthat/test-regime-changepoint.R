# Tests for R/regime_changepoint.R (Phase R2, issue #19 P3)
# Snapshot ratio target: >=30% of test_that blocks use expect_snapshot()
testthat::local_edition(3)

source("../../R/analysis_functions.R")  # STABLECOINS, needed by regime_changepoint()
source("../../R/regime_changepoint.R")

# ---- Synthetic test fixtures ----

make_regime_history <- function(n_days = 60, tokens = c("SOL"), seed = 42) {
  dates <- seq(Sys.time() - as.difftime(n_days, units = "days"), Sys.time(), by = "1 day")
  set.seed(seed)
  rows <- list()
  for (tok in tokens) {
    rows[[tok]] <- tibble::tibble(
      token = tok,
      price_usd = 80 * cumprod(c(1, exp(rnorm(length(dates) - 1, 0, 0.02)))),
      fetched_at = dates
    )
  }
  dplyr::bind_rows(rows)
}

# A synthetic series with a known variance break: 60 low-vol days, then
# 60 high-vol days -- mirrors the fixture style already used for
# regime_rollmad's own "detects high-vol regime" test.
make_regime_break_history <- function(token = "TEST", seed = 99) {
  set.seed(seed)
  n_low <- 60
  n_high <- 60
  low_returns  <- rnorm(n_low, 0, 0.005)
  high_returns <- rnorm(n_high, 0, 0.05)
  n_dates <- n_low + n_high + 1
  dates <- seq(Sys.time() - as.difftime(n_dates - 1, units = "days"), Sys.time(), by = "1 day")
  prices <- 100 * cumprod(c(1, exp(c(low_returns, high_returns))))
  tibble::tibble(token = token, price_usd = prices, fetched_at = dates)
}

# ---- Tests: regime_changepoint ----

test_that("regime_changepoint excludes stablecoins", {
  hist <- make_regime_history(60, tokens = c("SOL", "USDC"))
  result <- regime_changepoint(hist)
  expect_true(!"USDC" %in% result$token)
  expect_true("SOL" %in% result$token)
})

test_that("regime_changepoint returns NA below min_obs", {
  hist <- make_regime_history(10, tokens = "SOL")
  result <- regime_changepoint(hist, min_obs = 30)
  expect_true(all(is.na(result$regime_cpt)))
})

test_that("regime_changepoint output length matches input length", {
  hist <- make_regime_break_history()
  result <- regime_changepoint(hist)
  expect_equal(nrow(result), nrow(hist))
})

test_that("regime_changepoint detects a high-vol regime after a known variance break", {
  hist <- make_regime_break_history()
  result <- regime_changepoint(hist, min_obs = 30)
  last_30 <- result |>
    dplyr::filter(
      fetched_at >= max(fetched_at) - as.difftime(30, units = "days"),
      !is.na(regime_cpt)
    )
  expect_gt(nrow(last_30), 0)
  high_frac <- mean(last_30$regime_cpt == "high")
  expect_gt(high_frac, 0.5)
})

# SNAPSHOT: column shape
test_that("regime_changepoint output shape", {
  hist <- make_regime_break_history()
  expect_snapshot(names(regime_changepoint(hist, min_obs = 30)))
})

# SNAPSHOT: labelled regime distribution on the known-break fixture
test_that("regime_changepoint label distribution snapshot on a known break", {
  hist <- make_regime_break_history()
  result <- regime_changepoint(hist, min_obs = 30)
  expect_snapshot(table(result$regime_cpt, useNA = "ifany"))
})

test_that("regime_changepoint handles a degenerate (constant-price) series without erroring", {
  # cpt.var() can legitimately fail on a zero-variance series -- the
  # tryCatch path must return NA, not propagate the error.
  dates <- seq(Sys.time() - as.difftime(59, units = "days"), Sys.time(), by = "1 day")
  hist <- tibble::tibble(token = "FLAT", price_usd = rep(10, length(dates)), fetched_at = dates)
  result <- expect_no_error(regime_changepoint(hist, min_obs = 30))
  expect_equal(nrow(result), nrow(hist))
})

test_that("regime_changepoint empty input returns empty output with correct columns", {
  hist <- make_regime_history(60, tokens = "USDC")  # only a stablecoin -> filtered to empty
  result <- regime_changepoint(hist)
  expect_equal(nrow(result), 0)
  expect_named(result, c("token", "fetched_at", "regime_cpt"))
})

# ---- Tests: regime_consensus ----

test_that("regime_consensus: both methods agree gives confidence 1.0", {
  df <- tibble::tibble(
    token = "SOL", fetched_at = Sys.time(),
    regime_mad = "high", regime_cpt = "high"
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_equal(result$regime_consensus, "high")
  expect_equal(result$regime_confidence, 1.0)
})

test_that("regime_consensus: methods disagree gives confidence 0.5", {
  df <- tibble::tibble(
    token = "SOL", fetched_at = Sys.time(),
    regime_mad = "low", regime_cpt = "high"
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_equal(result$regime_confidence, 0.5)
  expect_true(result$regime_consensus %in% c("low", "high"))
})

test_that("regime_consensus: all methods NA gives NA consensus and 0 confidence", {
  df <- tibble::tibble(
    token = "SOL", fetched_at = Sys.time(),
    regime_mad = NA_character_, regime_cpt = NA_character_
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_true(is.na(result$regime_consensus))
  expect_equal(result$regime_confidence, 0)
})

test_that("regime_consensus: one method NA, one present -- consensus follows the present vote", {
  df <- tibble::tibble(
    token = "SOL", fetched_at = Sys.time(),
    regime_mad = "medium", regime_cpt = NA_character_
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_equal(result$regime_consensus, "medium")
  expect_equal(result$regime_confidence, 1.0)
})

test_that("regime_consensus: below the 0.67 plan-doc threshold is flagged uncertain by disagreement", {
  # With only 2 methods, any disagreement caps confidence at 0.5, which is
  # < 0.67 -- exactly what the plan doc's threshold is meant to catch.
  df <- tibble::tibble(
    token = c("SOL", "JUP"), fetched_at = Sys.time(),
    regime_mad = c("high", "low"), regime_cpt = c("high", "low")
  )
  agree <- regime_consensus(df[1, ], method_cols = c("regime_mad", "regime_cpt"))
  df2 <- tibble::tibble(token = "SOL", fetched_at = Sys.time(), regime_mad = "high", regime_cpt = "low")
  disagree <- regime_consensus(df2, method_cols = c("regime_mad", "regime_cpt"))
  expect_gte(agree$regime_confidence, 0.67)
  expect_lt(disagree$regime_confidence, 0.67)
})

# SNAPSHOT: disagreement case, full row
test_that("regime_consensus disagreement full output snapshot", {
  df <- tibble::tibble(
    token = "SOL",
    fetched_at = as.POSIXct("2026-09-23 00:00:00", tz = "UTC"),
    regime_mad = "high", regime_cpt = "low"
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_snapshot(result |> dplyr::select(token, regime_consensus, regime_confidence))
})

test_that("regime_consensus works row-wise across multiple tokens independently", {
  df <- tibble::tibble(
    token = c("SOL", "JUP", "BONK"),
    fetched_at = Sys.time(),
    regime_mad = c("high", "low", "medium"),
    regime_cpt = c("high", "low", "high")
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  # Row 3 (BONK) is a genuine disagreement between two present, non-NA votes
  # ("medium" vs "high") -- per regime_consensus()'s documented tie-break
  # (`sort(table(votes), decreasing = TRUE)[1]`), this resolves to one of the
  # two values, not NA (NA is reserved for zero non-NA votes). table()'s
  # alphabetical tie order picks "high" here.
  expect_equal(result$regime_consensus, c("high", "low", "high"))
  expect_equal(result$regime_confidence, c(1.0, 1.0, 0.5))
})

# SNAPSHOT: full output shape/values for a small multi-token table
test_that("regime_consensus full output snapshot", {
  df <- tibble::tibble(
    token = c("SOL", "JUP"),
    fetched_at = as.POSIXct("2026-09-23 00:00:00", tz = "UTC"),
    regime_mad = c("high", "low"),
    regime_cpt = c("high", "medium")
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_snapshot(
    result |> dplyr::select(token, regime_consensus, regime_confidence)
  )
})
