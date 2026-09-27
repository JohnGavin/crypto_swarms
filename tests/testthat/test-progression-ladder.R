# Tests for R/progression_ladder.R (issue #18, gap G9)
testthat::local_edition(3)

source("../../R/progression_ladder.R")

test_that("progression_ladder_status returns exactly the 8 named phases", {
  result <- progression_ladder_status()
  expect_equal(nrow(result), 8L)
  expect_equal(result$step, 1:8)
})

test_that("progression_ladder_status has the required columns", {
  result <- progression_ladder_status()
  expect_named(
    result,
    c("step", "phase", "indicator", "status", "current_value", "source", "note")
  )
})

test_that("every phase currently reads INDETERMINATE, not silently omitted", {
  # Per issue #18 G9's own instruction: "mark steps with no measurable
  # indicator as INDETERMINATE, not 'not reached'". As of this test, none
  # of gaps G1-G8 are built, so every row must be INDETERMINATE and every
  # row must carry a non-NA source naming what's missing -- a silently
  # blank source would be the same "not reached" conflation the issue
  # explicitly forbids.
  result <- progression_ladder_status()
  expect_true(all(result$status == "INDETERMINATE"))
  expect_true(all(is.na(result$current_value)))
  expect_false(any(is.na(result$source)))
  expect_false(any(is.na(result$note)))
})

test_that("no phase is silently dropped -- step numbers are contiguous 1-8", {
  # Falsifies the "every row INDETERMINATE" test above: if a phase were
  # dropped from PROGRESSION_LADDER_PHASES, step 1:8 would no longer be
  # contiguous and this would catch it even though the status/source
  # checks above would still pass on the remaining rows.
  result <- progression_ladder_status()
  expect_identical(sort(result$step), 1:8)
})

# SNAPSHOT: full table shape + values -- catches an accidental phase
# reorder, a status flip, or a source/note text change going unreviewed.
test_that("progression_ladder_status output snapshot", {
  result <- progression_ladder_status()
  expect_snapshot(result |> dplyr::select(step, phase, status, source))
})

test_that("PROGRESSION_LADDER_PHASES phase names match issue #18 G9's own text", {
  # Guards against the phase list drifting from what's actually documented
  # in the issue (this repo must not invent additional steps -- see the
  # file header's "ask for a paste, never reconstruct" rationale).
  result <- progression_ladder_status()
  expect_equal(
    result$phase,
    c(
      "Perp yield", "On-chain stocks", "Private trading",
      "Institutional lending", "Direct issuance", "CBDC corporate finance",
      "Private FX swaps", "Looped international fixed income"
    )
  )
})

# SNAPSHOT: indicator text -- catches an accidental wording drift that
# would otherwise only be caught by manually re-reading the report.
test_that("indicator descriptions snapshot", {
  result <- progression_ladder_status()
  expect_snapshot(result$indicator)
})
