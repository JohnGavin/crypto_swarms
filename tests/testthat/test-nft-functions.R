# Tests for R/nft_functions.R (issue #9)
# Snapshot ratio target: >=30% of test_that blocks use expect_snapshot()
testthat::local_edition(3)

source("../../R/nft_functions.R")

# ---- Synthetic test fixtures ----
#
# start_days_ago defaults to 10 (< NFT_WINDOW_DAYS=14) so every fixture row
# falls inside the rolling window by default -- override explicitly where a
# test specifically wants rows excluded by the cutoff.
make_nft_history <- function(floors, collection = "TestCol", start_days_ago = 10) {
  dates <- seq(Sys.time() - as.difftime(start_days_ago, units = "days"), Sys.time(),
               length.out = length(floors))
  tibble::tibble(
    collection = collection,
    slug = tolower(collection),
    floor_sol = floors,
    listed_count = 100L,
    avg_price_24h_sol = floors,
    volume_all_sol = 1000,
    fetched_at = dates
  )
}

# A realistically-jittered "stable" floor series -- NOT constant. A perfectly
# flat window has MAD == 0 (mad() of mostly-identical values is exactly 0),
# which correctly trips the nontrivial_mad gate and masks any single-point
# drop; that degenerate case is its OWN test below, not the default fixture.
STABLE_12 <- c(10.10, 9.90, 10.20, 9.80, 10.00, 10.10, 9.95, 10.05, 9.90, 10.10, 10.00, 9.95)

# ---- Tests: prepare_nft_history ----

test_that("prepare_nft_history parses fetched_at and sorts", {
  raw <- make_nft_history(c(10, 11, 9))
  raw$fetched_at <- as.character(raw$fetched_at)
  result <- prepare_nft_history(raw)
  expect_s3_class(result$fetched_at, "POSIXct")
  expect_true(all(diff(as.numeric(result$fetched_at)) >= 0))
})

# ---- Tests: compute_nft_window_summary ----

test_that("compute_nft_window_summary computes robust median/MAD", {
  hist <- prepare_nft_history(make_nft_history(STABLE_12))
  result <- compute_nft_window_summary(hist)
  expect_equal(result$floor_median_14d, median(STABLE_12))
  expect_equal(result$n_14d, length(STABLE_12))
  expect_gt(result$floor_mad_14d, 0)
})

test_that("compute_nft_window_summary excludes observations before the cutoff", {
  hist <- prepare_nft_history(make_nft_history(c(rep(100, 5), rep(10, 28)), start_days_ago = 40))
  result <- compute_nft_window_summary(hist, window_days = 14)
  expect_lt(result$n_14d, 33)
  expect_equal(result$floor_median_14d, 10)
})

# SNAPSHOT: column shape is part of the contract nft_alerts consumes
test_that("compute_nft_window_summary output shape", {
  hist <- prepare_nft_history(make_nft_history(STABLE_12))
  expect_snapshot(names(compute_nft_window_summary(hist)))
})

# ---- Tests: nft_latest_snapshot ----

test_that("nft_latest_snapshot picks the newest row per collection", {
  a <- make_nft_history(c(1, 2, 3), collection = "A")
  b <- make_nft_history(c(10, 20), collection = "B")
  hist <- prepare_nft_history(dplyr::bind_rows(a, b))
  result <- nft_latest_snapshot(hist)
  expect_equal(nrow(result), 2)
  expect_equal(result$floor_sol[result$collection == "A"], 3)
  expect_equal(result$floor_sol[result$collection == "B"], 20)
})

# ---- Tests: compute_nft_alerts ----

test_that("compute_nft_alerts flags a floor drop beyond 3 MADs", {
  floors <- c(STABLE_12, 5.0)
  hist <- prepare_nft_history(make_nft_history(floors))
  summary <- compute_nft_window_summary(hist)
  latest <- nft_latest_snapshot(hist)
  result <- compute_nft_alerts(latest, summary)
  expect_true(result$have_robust_history)
  expect_true(result$nontrivial_mad)
  expect_gt(result$floor_zscore, 3.0)
  expect_true(result$floor_drop_alert)
})

test_that("compute_nft_alerts does not flag a stable floor", {
  floors <- c(STABLE_12, 10.02)
  hist <- prepare_nft_history(make_nft_history(floors))
  summary <- compute_nft_window_summary(hist)
  latest <- nft_latest_snapshot(hist)
  result <- compute_nft_alerts(latest, summary)
  expect_lt(abs(result$floor_zscore), 3.0)
  expect_false(result$floor_drop_alert)
})

test_that("compute_nft_alerts does not flag a floor rise", {
  floors <- c(STABLE_12, 12.0)
  hist <- prepare_nft_history(make_nft_history(floors))
  summary <- compute_nft_window_summary(hist)
  latest <- nft_latest_snapshot(hist)
  result <- compute_nft_alerts(latest, summary)
  # A rise gives a NEGATIVE zscore under (median - floor) / mad; only a
  # positive zscore beyond the threshold counts as a drop.
  expect_lt(result$floor_zscore, 0)
  expect_false(result$floor_drop_alert)
})

test_that("compute_nft_alerts gates on minimum observation count", {
  floors <- c(rep(10, 5), 1)  # 6 obs, below NFT_MIN_OBS = 10
  hist <- prepare_nft_history(make_nft_history(floors))
  summary <- compute_nft_window_summary(hist)
  latest <- nft_latest_snapshot(hist)
  result <- compute_nft_alerts(latest, summary)
  expect_false(result$have_robust_history)
  expect_false(result$floor_drop_alert)
  expect_true(is.na(result$floor_zscore))
})

test_that("compute_nft_alerts gates on non-trivial relative MAD (near-flat window)", {
  # floor barely moves at all -- MAD is ~0, a real division risk without the gate
  floors <- c(rep(10.000, 27), 10.001)
  hist <- prepare_nft_history(make_nft_history(floors))
  summary <- compute_nft_window_summary(hist)
  latest <- nft_latest_snapshot(hist)
  result <- compute_nft_alerts(latest, summary)
  expect_true(result$have_robust_history)
  expect_false(result$nontrivial_mad)
  expect_true(is.na(result$floor_zscore))
  expect_false(result$floor_drop_alert)
})

# SNAPSHOT: full printed output for a single flagged drop -- catches
# regressions in values, not just column names.
test_that("compute_nft_alerts full output for a flagged drop", {
  floors <- c(STABLE_12, 5.0)
  hist <- prepare_nft_history(make_nft_history(floors))
  summary <- compute_nft_window_summary(hist)
  latest <- nft_latest_snapshot(hist)
  result <- compute_nft_alerts(latest, summary) |>
    dplyr::select(collection, floor_sol, floor_median_14d, n_14d, floor_drop_alert)
  expect_snapshot(print(result))
})

test_that("compute_nft_alerts handles multiple collections independently", {
  a <- make_nft_history(c(STABLE_12, 5.0), collection = "Dropping")
  b <- make_nft_history(rep(20, 13), collection = "Stable")
  hist <- prepare_nft_history(dplyr::bind_rows(a, b))
  summary <- compute_nft_window_summary(hist)
  latest <- nft_latest_snapshot(hist)
  result <- compute_nft_alerts(latest, summary)
  expect_true(result$floor_drop_alert[result$collection == "Dropping"])
  expect_false(result$floor_drop_alert[result$collection == "Stable"])
})
