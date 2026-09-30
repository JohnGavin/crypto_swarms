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

test_that("segment_mad_labels: fewer than 2 segments returns all NA, not a degenerate 'low'", {
  # Reproduces #32 finding 2: with 1 segment, the old code's quantile split
  # collapsed to a single constant value, so every observation -- however
  # volatile -- was labelled "low". A single segment cannot be
  # tertile-classified against itself; it must return NA, not a guess.
  returns <- rnorm(50, 0, 0.05)  # deliberately high-vol
  seg_id <- rep(1L, 50)
  result <- segment_mad_labels(returns, seg_id)
  expect_true(all(is.na(result)))
  expect_length(result, 50)
})

test_that("segment_mad_labels: multiple segments that all share the same MAD return all NA", {
  # Reproduces #32 finding 2's follow-up review: the original fix only
  # checked length(per_segment_mad) < 2 (segment COUNT), not whether the
  # segments' MAD values are actually distinct. Several single-observation
  # segments (each MAD 0, since a lone point has no internal spread to
  # measure) reproduce the exact same degeneracy the 1-segment fix was
  # meant to close: q33 == q67 == 0, so case_when()'s first branch matches
  # every row -- "low" regardless of anything.
  seg_id <- c(1L, 2L, 3L)  # 3 segments, each a single observation
  returns <- c(0.5, -3, 10)  # wildly different VALUES, but MAD is 0 for all
  result <- segment_mad_labels(returns, seg_id)
  expect_true(all(is.na(result)))
  expect_length(result, 3)
})

test_that("segment_mad_labels: exactly 2 segments with distinct MAD classify low/high, not NA", {
  # 2 segments IS enough to classify (unlike the 1-segment case above): with
  # two distinct seg_mad values, tertile quantiles never collapse to a
  # constant, so the lower-MAD segment reads "low" and the higher "high".
  # This must keep working -- it's exactly the shape of the project's own
  # canonical break fixture (make_regime_break_history()).
  set.seed(100)
  seg_id <- c(rep(1L, 30), rep(2L, 30))
  returns <- c(rnorm(30, 0, 0.005), rnorm(30, 0, 0.05))
  result <- segment_mad_labels(returns, seg_id)
  expect_false(any(is.na(result)))
  expect_true(all(result[seg_id == 1] == "low"))
  expect_true(all(result[seg_id == 2] == "high"))
})

test_that("segment_mad_labels: label reflects per-segment MAD, not per-observation weighting", {
  # Reproduces #32 finding 3: one huge low-vol segment (100 obs) alongside
  # two tiny segments (5 obs each) with genuinely higher internal spread.
  # A single-observation segment has MAD 0 regardless of its value's
  # magnitude (no internal spread to measure), so each segment here needs
  # >1 observation for its MAD to mean anything. Each segment must count
  # ONCE in the tertile split, not be weighted by how many observations it
  # has -- otherwise the 100-observation segment would dominate the
  # quantiles and swallow the other two.
  set.seed(101)
  seg_id <- c(rep(1L, 100), rep(2L, 5), rep(3L, 5))
  returns <- c(rnorm(100, 0, 0.005), rnorm(5, 0, 0.02), rnorm(5, 0, 0.08))
  result <- segment_mad_labels(returns, seg_id)
  # Three segments, three distinct per-segment MAD values -> one label each.
  labels_by_segment <- tapply(result, seg_id, unique)
  expect_length(unique(unlist(labels_by_segment)), 3)
  expect_setequal(unlist(labels_by_segment), c("low", "medium", "high"))
  # Segment 1 (tightest spread) must be "low" regardless of its 100x length.
  expect_equal(labels_by_segment[["1"]], "low")
  expect_equal(labels_by_segment[["3"]], "high")
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
  expect_equal(result$regime_n_votes, 2)
})

test_that("regime_consensus: methods disagree gives confidence 0.5", {
  df <- tibble::tibble(
    token = "SOL", fetched_at = Sys.time(),
    regime_mad = "low", regime_cpt = "high"
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_equal(result$regime_confidence, 0.5)
  expect_true(result$regime_consensus %in% c("low", "high"))
  expect_equal(result$regime_n_votes, 2)
})

test_that("regime_consensus: all methods NA gives NA consensus and 0 confidence", {
  df <- tibble::tibble(
    token = "SOL", fetched_at = Sys.time(),
    regime_mad = NA_character_, regime_cpt = NA_character_
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_true(is.na(result$regime_consensus))
  expect_equal(result$regime_confidence, 0)
  expect_equal(result$regime_n_votes, 0)
})

test_that("regime_consensus: one method NA, one present -- consensus follows the present vote", {
  df <- tibble::tibble(
    token = "SOL", fetched_at = Sys.time(),
    regime_mad = "medium", regime_cpt = NA_character_
  )
  result <- regime_consensus(df, method_cols = c("regime_mad", "regime_cpt"))
  expect_equal(result$regime_consensus, "medium")
  expect_equal(result$regime_confidence, 1.0)
  # regime_n_votes distinguishes THIS case (1 method voted, confidence
  # trivially 1.0) from genuine 2-method agreement -- see #32 finding 1's
  # follow-up review. regime_shock_flag() relies on this distinction.
  expect_equal(result$regime_n_votes, 1)
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

# ---- Tests: regime_shock_flag (#32 finding 1) ----

test_that("regime_shock_flag: up transition with full confidence and 2 votes is a shock", {
  result <- regime_shock_flag(
    is_transition = TRUE, transition_direction = "up",
    regime_confidence = 1.0, regime_n_votes = 2
  )
  expect_true(result)
})

test_that("regime_shock_flag: up transition on a 0.5-confidence tie is NOT a shock", {
  # Reproduces #32 finding 1 directly: with only 2 methods, every
  # disagreement ties at confidence 0.5. _targets.R used to set regime_shock
  # from is_transition/transition_direction alone, so a single method's
  # vote could flip the "consensus" to "up" and raise a real alert. The
  # plan doc's own threshold (0.67) says this is exactly the uncertain case.
  result <- regime_shock_flag(
    is_transition = TRUE, transition_direction = "up",
    regime_confidence = 0.5, regime_n_votes = 2
  )
  expect_false(result)
})

test_that("regime_shock_flag: full confidence but only 1 vote is NOT a shock", {
  # Reproduces #32 finding 1's follow-up review directly: with only ONE
  # method voting (the other is NA), regime_confidence is trivially 1.0 --
  # the single vote agrees with itself. Gating on confidence alone let a
  # lone method's "up" call through unchallenged, exactly the single-method
  # alert failure mode this function exists to prevent. This case became
  # MORE common once segment_mad_labels() started correctly returning NA
  # for a degenerate segment split (previously it wrongly guessed "low").
  result <- regime_shock_flag(
    is_transition = TRUE, transition_direction = "up",
    regime_confidence = 1.0, regime_n_votes = 1
  )
  expect_false(result)
})

test_that("regime_shock_flag: confidence exactly at the 0.67 threshold is a shock (inclusive)", {
  result <- regime_shock_flag(
    is_transition = TRUE, transition_direction = "up",
    regime_confidence = 0.67, regime_n_votes = 2
  )
  expect_true(result)
})

test_that("regime_shock_flag: down transition is never a shock regardless of confidence", {
  result <- regime_shock_flag(
    is_transition = TRUE, transition_direction = "down",
    regime_confidence = 1.0, regime_n_votes = 2
  )
  expect_false(result)
})

test_that("regime_shock_flag: no transition is never a shock", {
  result <- regime_shock_flag(
    is_transition = FALSE, transition_direction = NA_character_,
    regime_confidence = 1.0, regime_n_votes = 2
  )
  expect_false(result)
})

test_that("regime_shock_flag: NA confidence is treated as 0 (never a shock)", {
  result <- regime_shock_flag(
    is_transition = TRUE, transition_direction = "up",
    regime_confidence = NA_real_, regime_n_votes = 2
  )
  expect_false(result)
})

test_that("regime_shock_flag: NA n_votes is treated as 0 (never a shock)", {
  result <- regime_shock_flag(
    is_transition = TRUE, transition_direction = "up",
    regime_confidence = 1.0, regime_n_votes = NA_integer_
  )
  expect_false(result)
})

test_that("regime_shock_flag: vectorised across multiple tokens", {
  result <- regime_shock_flag(
    is_transition = c(TRUE, TRUE, TRUE, FALSE, TRUE),
    transition_direction = c("up", "up", "down", NA_character_, "up"),
    regime_confidence = c(1.0, 0.5, 1.0, NA_real_, 1.0),
    regime_n_votes = c(2, 2, 2, NA_integer_, 1)
  )
  expect_equal(result, c(TRUE, FALSE, FALSE, FALSE, FALSE))
})
