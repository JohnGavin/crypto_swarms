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

#' Change-point detection on return variance (Phase R2 Method 3).
#'
#' Fits `changepoint::cpt.var()` (PELT) per token on log returns, then maps
#' each detected segment to low/medium/high by tertile-classifying that
#' segment's own MAD against the token's own segment-MAD distribution -- the
#' same robust tertile approach `regime_rollmad()` uses, so the two methods'
#' labels are on a comparable scale even though they're derived differently.
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

      seg_mad <- vapply(
        seg_id,
        function(s) mad(returns[seg_id == s], na.rm = TRUE),
        numeric(1)
      )
      q33 <- quantile(seg_mad, 0.33, na.rm = TRUE)
      q67 <- quantile(seg_mad, 0.67, na.rm = TRUE)
      regime_cpt <- case_when(
        seg_mad <= q33 ~ "low",
        seg_mad >= q67 ~ "high",
        TRUE            ~ "medium"
      )

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
#' @return regime_methods_df with two added columns:
#'   regime_consensus  -- modal regime across the non-NA votes (NA if none)
#'   regime_confidence -- fraction of non-NA votes agreeing with the mode
#'     (0 when there are no votes; per the plan doc, confidence < 0.67 means
#'     the regime is uncertain -- with only 2 methods that is every
#'     disagreement, which is the correct reading until a 3rd method ships)
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
      }
    ) |>
    ungroup() |>
    select(-.votes)
}
