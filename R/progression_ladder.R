# Progression ladder tracker (issue #18, gap G9).
#
# Context (from issue #18, paraphrased by the repo owner from an external
# commentary thread read for ideas only -- per external-code-zero-trust,
# nothing from that thread is reproduced here beyond the repo owner's own
# 8-phase paraphrase already committed to the issue text): "The essay's
# 13-step ladder (perp yield -> on-chain stocks -> private trading ->
# institutional lending -> direct issuance -> CBDC corporate finance ->
# private FX swaps -> looped international fixed income) gives a natural
# dashboard. Add a report section listing each step with (a) an observable
# indicator, (b) current status, (c) data source, and mark steps with no
# measurable indicator as INDETERMINATE, not 'not reached'."
#
# The issue's own text names 8 phases with "13-step"/"Step 9" language
# elsewhere -- a lossy paraphrase of an essay this repo never ingested and
# must not reconstruct (per the "ask for a paste, never reconstruct"
# discipline). This tracker covers exactly the 8 phases named in G9's own
# text, no more, no fewer; it does not invent additional steps to reach 13.
#
# As of this file's creation, every one of G1-G8's own data sources (supply,
# volume, RWA universe, macro, FX, freeze events, privacy coverage, fee
# economics) is still unbuilt, so every phase below is genuinely
# INDETERMINATE -- not a placeholder bug, the honest current state. That is
# the point: this table makes the instrumentation gap explicit and auditable
# in the report, rather than leaving it silently absent. As G1-G8 land, flip
# the matching row's status/source/current_value here -- this file is the
# single place that changes.

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

#' The 8 phases named in issue #18's G9 text, in order.
#'
#' Kept as a package-level constant (not inline in progression_ladder_status())
#' so a future status update touches exactly one place per phase.
PROGRESSION_LADDER_PHASES <- tibble::tribble(
  ~step, ~phase,                          ~indicator,
  1L,    "Perp yield",                    "Funding-rate level/trend on Hyperliquid-style perps for equity-like/index proxies",
  2L,    "On-chain stocks",                "Price-vs-underlying peg/premium and liquidity for tokenized-equity instruments (G3)",
  3L,    "Private trading",                "Volume or venue-share data for permissioned/private on-chain trading venues",
  4L,    "Institutional lending",          "TVL or origination volume for institutional on-chain lending desks",
  5L,    "Direct issuance",                "Count/value of new direct on-chain corporate debt or equity issuance events",
  6L,    "CBDC corporate finance",         "Any CBDC-denominated corporate-finance activity (issuance, settlement volume)",
  7L,    "Private FX swaps",               "Volume of privately-negotiated on-chain FX swaps referencing non-USD stablecoins (G5)",
  8L,    "Looped international fixed income", "Cross-border tokenized fixed-income positions referencing each other (looping)"
)

#' Status of the G9 progression ladder against currently-available signals.
#'
#' Every phase is assessed against what this repo's pipeline actually
#' measures today (16 Solana token prices/liquidity, stablecoin depeg,
#' NFT floors, regime detection -- see docs/REGIME_DETECTION_PLAN.md). None
#' of G1-G8's planned data sources are built yet, so every row currently
#' resolves to INDETERMINATE with a `source` naming the gap that would need
#' to close first. This function has no data dependency (reads no upstream
#' target) precisely because there is no live signal to read yet -- see the
#' file header for how this changes as gaps close.
#'
#' @return tibble: step, phase, indicator, status ("measured" | "INDETERMINATE"),
#'   current_value (NA_character_ until measured), source (gap reference +
#'   what's missing), note.
progression_ladder_status <- function() {
  PROGRESSION_LADDER_PHASES |>
    dplyr::mutate(
      status = "INDETERMINATE",
      current_value = NA_character_,
      source = dplyr::case_when(
        step %in% c(1L)          ~ "Hyperliquid funding rates -- planned, #19 P2 / historical#870, not yet consumed",
        step %in% c(2L, 5L)      ~ "RWA / tokenized-equity universe -- planned, #18 gap G3, not started",
        step %in% c(3L, 4L, 6L)  ~ "No candidate data source identified -- not started",
        step %in% c(7L)          ~ "Non-USD stablecoin + FX tracking -- planned, #18 gap G5, not started",
        step %in% c(8L)          ~ "Cross-border tokenized fixed-income linkage -- no candidate data source identified"
      ),
      note = "No measurable indicator exists in this pipeline yet; reported as INDETERMINATE per issue #18 G9, not silently omitted."
    ) |>
    dplyr::select(step, phase, indicator, status, current_value, source, note)
}
