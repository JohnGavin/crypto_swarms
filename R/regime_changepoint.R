# Regime detection Phase R2 (issue #19 P3): change-point method + consensus.
#
# Kept in a separate file from R/analysis_functions.R for the same modularity
# reason as R/nft_functions.R -- not a T dependency-inference workaround this
# time (regime_changepoint()/regime_consensus() are called from INSIDE the
# existing `analysis` rn node's tar_make(), same as Phase R1; no new rn/pyn
# node is added, so the comment-lexing dependency-inference issue documented
# in R/nft_functions.R and https://github.com/b-rodrigues/tlang/issues/527
# does not apply here).
#
# Per docs/REGIME_DETECTION_PLAN.md's phased rollout: Phase R1 (rolling MAD,
# R/analysis_functions.R::regime_rollmad) shipped first. This is Phase R2:
# Method 3 (change-point on return variance) plus the mandatory consensus
# vote across methods. Method 2 (HMM, depmixS4) remains unshipped -- the
# consensus function below is written for N methods, not hardcoded to 2, so
# adding a third vote later is a one-line change to METHOD_COLS at the call
# site, not a rewrite.

suppressPackageStartupMessages({
  library(dplyr)
  library(changepoint)
})

# Per the plan doc: change-point detection needs more history than rolling
# MAD to be meaningful (a single-window MAD needs 10 obs; a PELT fit over the
# whole series needs enough for at least a few candidate segments).
REGIME_CPT_MIN_OBS <- 30

#' Label each observation's PELT segment by tertile of that segment's OWN
#' MAD, computed once per segment (not re-weighted by segment length).
#'
#' Fixes two bugs found in review (#32):
#'
#' 1. With a single segment (PELT found no change point), the old code
#'    computed `mad()` of the whole series, so q33 == q67 == that one value
#'    and `case_when()`'s first branch (`seg_mad <= q33`) always matched --
#'    every observation was labelled "low" regardless of true volatility.
#'    A single segment cannot be tertile-classified against itself; this
#'    now returns NA for the whole series instead of guessing. Two segments
#'    with distinct MAD values do NOT collapse this way (quantile() over two
#'    distinct values always splits strictly between them), so the common
#'    single-break case is unaffected and still classifies to low/high.
#' 2. The old code used `vapply()` over one entry per OBSERVATION, so a long
#'    segment's MAD was recomputed once per observation (O(n^2)) and the
#'    tertile quantiles were implicitly weighted by segment length rather
#'    than treating each segment as one vote. This computes MAD once per
#'    unique segment and quantiles over those per-segment values only.
#'
#' @param returns Numeric vector of returns, one per observation.
#' @param seg_id Integer vector, same length as `returns`: which PELT
#'   segment each observation belongs to.
#' @return Character vector, same length as `returns`: low/medium/high per
#'   observation. All NA when there are fewer than 2 DISTINCT per-segment
#'   MAD values (a single segment always qualifies; so does any number of
#'   segments that all happen to share the same MAD -- e.g. several
#'   constant-price or single-observation segments -- see #32 finding 2 on
#'   the followup review of this function's own first fix).
segment_mad_labels <- function(returns, seg_id) {
  # c() strips tapply()'s 1D-array class (keeping names) -- case_when()
  # rejects an array as "not a logical vector" once compared.
  per_segment_mad <- c(tapply(returns, seg_id, mad, na.rm = TRUE))

  if (length(unique(per_segment_mad)) < 2) {
    return(rep(NA_character_, length(returns)))
  }

  q33 <- quantile(per_segment_mad, 0.33, na.rm = TRUE)
  q67 <- quantile(per_segment_mad, 0.67, na.rm = TRUE)
  seg_label <- case_when(
    per_segment_mad <= q33 ~ "low",
    per_segment_mad >= q67 ~ "high",
    TRUE                   ~ "medium"
  )
  names(seg_label) <- names(per_segment_mad)
  unname(seg_label[as.character(seg_id)])
}

#' Change-point detection on return variance (Phase R2 Method 3).
#'
#' Fits `changepoint::cpt.var()` (PELT) per token on log returns, then maps
#' each detected segment to low/medium/high via `segment_mad_labels()` --
#' the same robust tertile approach `regime_rollmad()` uses, so the two
#' methods' labels are on a comparable scale even though derived differently.
#'
#' Known limitation (#32 finding 4, documented rather than fixed here): the
#' PELT fit runs over each token's FULL history every call, so the regime
#' label assigned to a past observation can change between runs as new data
#' arrives -- there is no guarantee a label computed today matches what an
#' expanding-window fit would have said at that point in time. This means
#' `regime_transitions()`'s `prev_regime` (and any transition derived from
#' it) can appear or disappear between runs with no new price move at the
#' latest point. Fixing this properly needs an expanding-window refit (or
#' persisting each run's latest label rather than recomputing it), which is
#' a larger, separately-scoped change -- see issue #32.
#'
#' @param hist data.frame: token, price_usd, fetched_at (POSIXct), sorted
#' @param min_obs Minimum return observations before change-point detection
#'   runs (default REGIME_CPT_MIN_OBS = 30, per the plan doc)
#' @param penalty changepoint::cpt.var() penalty (default "BIC")
#' @return data.frame: token, fetched_at, regime_cpt (low/medium/high/NA)
regime_changepoint <- function(hist, min_obs = REGIME_CPT_MIN_OBS, penalty = "BIC") {
  hist <- hist |> filter(!(token %in% STABLECOINS))

  if (nrow(hist) == 0) {
    return(tibble::tibble(
      token = character(), fetched_at = as.POSIXct(character()),
      regime_cpt = character()
    ))
  }

  hist |>
    group_by(token) |>
    arrange(fetched_at, .by_group = TRUE) |>
    group_modify(function(.x, .y) {
      returns <- diff(log(.x$price_usd))
      n <- length(returns)

      if (n < min_obs) {
        return(tibble::tibble(
          fetched_at = .x$fetched_at,
          regime_cpt = NA_character_
        ))
      }

      cpt <- tryCatch(
        changepoint::cpt.var(returns, method = "PELT", penalty = penalty),
        error = function(e) {
          cli::cli_warn(c(
            "!" = "regime_changepoint: cpt.var() failed for token {.val {.y$token}}: {conditionMessage(e)}",
            "i" = "Returning NA regime_cpt for this token; other methods still vote."
          ))
          NULL
        }
      )
      if (is.null(cpt)) {
        return(tibble::tibble(
          fetched_at = .x$fetched_at,
          regime_cpt = NA_character_
        ))
      }

      # cpt@cpts always ends with n (changepoint's own convention: the last
      # "changepoint" is the series end, closing the final segment).
      changes <- cpt@cpts
      seg_id <- integer(n)
      start <- 1L
      for (i in seq_along(changes)) {
        seg_id[start:changes[i]] <- i
        start <- changes[i] + 1L
      }

      regime_cpt <- segment_mad_labels(returns, seg_id)

      # returns[i] is the jump INTO observation i+1 (diff() drops the first
      # price); regime_rollmad() aligns the same way via c(NA, diff(...)).
      # Match that alignment here so regime_mad/regime_cpt line up on the
      # same fetched_at for the consensus join.
      tibble::tibble(
        fetched_at = .x$fetched_at,
        regime_cpt = c(NA_character_, regime_cpt)
      )
    }) |>
    ungroup()
}

#' Majority-vote consensus across N regime-detection methods.
#'
#' @param regime_methods_df data.frame with `token`, `fetched_at`, and one
#'   column per method named in `method_cols` (each low/medium/high/NA)
#' @param method_cols Character vector of column names to vote across
#' @return regime_methods_df with three added columns:
#'   regime_consensus  -- modal regime across the non-NA votes (NA if none)
#'   regime_confidence -- fraction of non-NA votes agreeing with the mode
#'     (0 when there are no votes; per the plan doc, confidence < 0.67 means
#'     the regime is uncertain -- with only 2 methods that is every
#'     disagreement, which is the correct reading until a 3rd method ships)
#'   regime_n_votes    -- count of non-NA votes (0 to length(method_cols)).
#'     Needed because confidence alone cannot distinguish "all methods
#'     agree" from "only one method voted" -- both read 1.0. See #32
#'     finding 1 on `regime_shock_flag()`'s follow-up review: a NA vote
#'     from one method previously made the remaining method's confidence
#'     trivially 1.0, defeating the multi-method gate entirely.
#'
#' Tie-break on disagreement: `sort(table(votes), decreasing = TRUE)[1]`
#' (the plan doc's own formula) resolves ties by table()'s default factor
#' ordering (alphabetical: "high" < "low" < "medium"), so a 2-way
#' low/high tie resolves to "high". This is a real, documented consequence
#' of reusing the plan's own consensus formula, not an arbitrary addition.
regime_consensus <- function(regime_methods_df, method_cols) {
  regime_methods_df |>
    rowwise() |>
    mutate(
      .votes = list(stats::na.omit(c_across(all_of(method_cols)))),
      regime_consensus = if (length(.votes) == 0) {
        NA_character_
      } else {
        names(sort(table(unlist(.votes)), decreasing = TRUE))[1]
      },
      regime_confidence = if (length(.votes) == 0) {
        0
      } else {
        max(table(unlist(.votes))) / length(.votes)
      },
      regime_n_votes = length(.votes)
    ) |>
    ungroup() |>
    select(-.votes)
}

#' Gate an "up" regime transition into a shock/alert signal by consensus
#' confidence.
#'
#' Fixes #32 finding 1: `_targets.R`'s `alert_summary` target used to set
#' `regime_shock` from `is_transition`/`transition_direction` alone, with no
#' gate on `regime_confidence`. With only 2 methods, every disagreement ties
#' at confidence 0.5 (see `regime_consensus()`'s own tie-break, which is
#' unchanged by this fix), so a single method's vote could flip the
#' "consensus" to "up" and raise a real alert -- looser than the Phase R1
#' behaviour it replaced. The plan doc's own threshold (confidence < 0.67 is
#' uncertain) already existed as a comment; it was just never applied here.
#'
#' The confidence-only gate above was itself found insufficient in the
#' follow-up review of this fix: when only ONE method votes (the other's
#' value is NA -- now more common since `segment_mad_labels()` correctly
#' returns NA for a degenerate segment split), `regime_confidence` is
#' trivially 1.0 (the single vote agrees with itself), so a lone method's
#' "up" call sails past the 0.67 gate unchallenged -- exactly the single-
#' method-alert failure mode this function exists to prevent. `min_votes`
#' additionally requires at least `min_votes` methods to have actually
#' voted (non-NA) before a shock can fire at all.
#'
#' @param is_transition Logical vector (as produced by `regime_transitions()`)
#' @param transition_direction Character vector: "up"/"down"/"lateral"/NA
#' @param regime_confidence Numeric vector, 0-1 (as produced by
#'   `regime_consensus()`). NA is treated as 0 (never a shock).
#' @param regime_n_votes Integer vector: count of non-NA votes (as produced
#'   by `regime_consensus()`). NA is treated as 0 (never a shock).
#' @param confidence_threshold Minimum confidence to treat an "up" transition
#'   as a shock (default 0.67, per docs/REGIME_DETECTION_PLAN.md)
#' @param min_votes Minimum number of methods that must have actually voted
#'   (default 2 -- the number of methods currently configured in
#'   `_targets.R`'s `regime_consensus_tbl`; update this default alongside
#'   `method_cols` when a 3rd method ships)
#' @return Logical vector, same length as the inputs
regime_shock_flag <- function(is_transition, transition_direction, regime_confidence,
                               regime_n_votes, confidence_threshold = 0.67, min_votes = 2) {
  regime_confidence[is.na(regime_confidence)] <- 0
  regime_n_votes[is.na(regime_n_votes)] <- 0
  !is.na(is_transition) & is_transition &
    !is.na(transition_direction) & transition_direction == "up" &
    regime_confidence >= confidence_threshold &
    regime_n_votes >= min_votes
}
