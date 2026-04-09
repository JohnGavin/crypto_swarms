# Volatility Regime Detection Plan

Multi-method framework for classifying crypto tokens into volatility regimes
(low / medium / high) and detecting regime transitions.

## Motivation

A single volatility threshold ("high vol if SD > X") is unreliable because:

- Regime transitions are what we care about, not absolute levels
- Different detection methods have different failure modes — ensemble them
- Crypto has fat-tailed returns, volatility clustering, and sudden regime shifts
- A single method ranks jittery-but-stable tokens the same as quietly-changing ones

## Design principles (from `~/.claude/rules/*`)

| Rule | How it applies |
|------|---------------|
| `robust-statistics` | Median + MAD on returns, NEVER mean + SD |
| `composite-alert-scoring` | Abnormality gate × direction modifier × range-width norm |
| `half-life-decay` | Time-decay weighting uses `2^(-d/h)`, NOT `exp(-d/h)` |
| `statistical-reporting` | Effect sizes before p-values; adjusted if multiple tests |
| `reproducible-visualization` | Regime assignments as targets, plots read them |
| Multi-method ensemble | Methods disagree when data is ambiguous — show it |

## Methods (ranked by complexity)

### Method 1: Rolling MAD of log returns (baseline)

**Approach:** Compute MAD of log returns over a 14-day rolling window.
Classify into tertiles across the full history: low = bottom 33%, high = top 33%.

```r
# In R/regime_detection.R
regime_rollmad <- function(history_df, window_days = 14) {
  history_df |>
    group_by(token) |>
    arrange(fetched_at, .by_group = TRUE) |>
    mutate(
      log_return = c(NA, diff(log(price_usd))),
      vol_mad_14d = slider::slide_index_dbl(
        log_return,
        fetched_at,
        .f = ~ mad(.x, na.rm = TRUE),
        .before = lubridate::days(window_days),
        .complete = FALSE
      )
    ) |>
    ungroup() |>
    group_by(token) |>
    mutate(
      regime_low_threshold  = quantile(vol_mad_14d, 0.33, na.rm = TRUE),
      regime_high_threshold = quantile(vol_mad_14d, 0.67, na.rm = TRUE),
      regime_mad = case_when(
        is.na(vol_mad_14d) ~ NA_character_,
        vol_mad_14d < regime_low_threshold  ~ "low",
        vol_mad_14d > regime_high_threshold ~ "high",
        TRUE ~ "medium"
      )
    ) |>
    ungroup()
}
```

**Pros:** Simple, interpretable, robust to outliers, fast.
**Cons:** Threshold-based, no probabilistic assignment.
**Requires:** ≥30 observations per token.

---

### Method 2: Hidden Markov Model (HMM) on returns

**Approach:** Fit a 2-state (or 3-state) Gaussian-mixture HMM on log returns
using `depmixS4`. Each state corresponds to a volatility regime.

```r
# depmixS4 not currently in deps — would add as needed
regime_hmm <- function(history_df, n_states = 3) {
  history_df |>
    group_by(token) |>
    arrange(fetched_at, .by_group = TRUE) |>
    group_modify(~{
      returns <- diff(log(.x$price_usd))
      if (length(returns) < 50) return(tibble(regime_hmm = NA_character_))
      mod <- depmixS4::depmix(
        returns ~ 1,
        data = data.frame(returns = returns),
        nstates = n_states,
        family = gaussian()
      )
      fit <- depmixS4::fit(mod, verbose = FALSE)
      states <- depmixS4::posterior(fit)$state
      # Reorder so state 1 = low vol, state n = high vol
      # (by fitted variance)
      ...
      tibble(regime_hmm = c(NA, regime_labels[states]))
    })
}
```

**Pros:** Probabilistic regime assignment, handles volatility clustering.
**Cons:** Computationally heavy; fragile to initialization; `depmixS4` adds dep.
**Requires:** ≥50 observations per token; retrained periodically.

---

### Method 3: Change-point detection on variance

**Approach:** Use `changepoint::cpt.var()` (PELT algorithm) to find discrete
variance change points in the return series. Assigns a "regime_id" to each
segment.

```r
regime_changepoint <- function(history_df, penalty = "BIC") {
  history_df |>
    group_by(token) |>
    arrange(fetched_at, .by_group = TRUE) |>
    group_modify(~{
      returns <- diff(log(.x$price_usd))
      if (length(returns) < 30) return(tibble(regime_cpt_id = NA_integer_))
      cpt <- changepoint::cpt.var(
        returns, method = "PELT", penalty = penalty
      )
      changes <- cpt@cpts
      regime_ids <- rep(NA, length(returns))
      start <- 1
      for (i in seq_along(changes)) {
        regime_ids[start:changes[i]] <- i
        start <- changes[i] + 1
      }
      tibble(regime_cpt_id = c(NA, regime_ids))
    }) |>
    ungroup()
}
```

**Pros:** Explicit regime-change events; good for retrospective labelling.
**Cons:** Penalty choice is sensitive; no forward prediction.
**Requires:** ≥30 observations per token; `changepoint` package.

---

### Method 4: K-means on volatility features (non-parametric)

**Approach:** Compute rolling features (MAD, skew, kurtosis, range) then
k-means cluster into k=3 regimes. Label clusters by increasing median MAD.

**Pros:** No distributional assumptions; extensible with more features.
**Cons:** Hard interpretability; clusters shift as data grows.
**Requires:** ≥50 observations; `cluster` or base `kmeans()`.

---

### Method 5: GARCH(1,1) conditional variance

**Approach:** Fit a GARCH(1,1) model via `rugarch`. Use conditional volatility
`sigma_t` to classify regimes.

**Pros:** Captures volatility clustering explicitly; theoretically grounded.
**Cons:** Heavy; fragile to outliers; `rugarch` is a large dep.
**Requires:** ≥100 observations; `rugarch` package.

**Recommendation:** Skip GARCH for now. Reconsider if simple methods are insufficient.

---

## Consensus regime (MANDATORY)

When running multiple methods, produce a **consensus regime** via majority vote:

```r
regime_consensus <- function(per_method_df) {
  # per_method_df has columns: token, fetched_at, regime_mad, regime_hmm, regime_cpt_id
  # Normalize all to low/medium/high labels
  per_method_df |>
    mutate(
      # Map change-point ids to regime by median MAD of that segment
      regime_cpt = map_cpt_to_level(regime_cpt_id, vol_mad_14d)
    ) |>
    rowwise() |>
    mutate(
      votes = list(c(regime_mad, regime_hmm, regime_cpt)),
      regime_consensus = {
        votes <- na.omit(unlist(votes))
        if (length(votes) == 0) NA_character_
        else names(sort(table(votes), decreasing = TRUE))[1]
      },
      regime_confidence = {
        votes <- na.omit(unlist(votes))
        if (length(votes) == 0) 0
        else max(table(votes)) / length(votes)
      }
    ) |>
    ungroup()
}
```

- `regime_consensus` = modal regime across methods
- `regime_confidence` = fraction of methods agreeing (1.0 = all agree, 0.33 = all disagree on 3 methods)
- When confidence < 0.67, the regime is **uncertain** — flag for human review

---

## Regime transition detection

A transition is more actionable than a steady-state regime:

```r
regime_transitions <- function(regime_df) {
  regime_df |>
    group_by(token) |>
    arrange(fetched_at, .by_group = TRUE) |>
    mutate(
      prev_regime = lag(regime_consensus),
      is_transition = !is.na(prev_regime) &
                      !is.na(regime_consensus) &
                      prev_regime != regime_consensus,
      transition_direction = case_when(
        !is_transition ~ NA_character_,
        prev_regime == "low"    & regime_consensus %in% c("medium", "high") ~ "up",
        prev_regime == "medium" & regime_consensus == "high" ~ "up",
        prev_regime == "high"   & regime_consensus %in% c("medium", "low")  ~ "down",
        prev_regime == "medium" & regime_consensus == "low"  ~ "down",
        TRUE ~ "lateral"
      )
    ) |>
    ungroup()
}
```

**Alert rule:** a transition from `low` → `high` within one period is a
high-priority alert (volatility shock). Wire into `compute_alerts()` as a new
trigger alongside `depeg_alert`, `price_anomaly`, `bb_break`, `liquidity_alert`.

---

## Proposed targets integration

Add to `_targets.R`:

```r
list(
  ...existing targets...,

  # Per-method regime classification (run in parallel via crew)
  tar_target(regime_rollmad_tbl,    regime_rollmad(history_prepped)),
  tar_target(regime_changepoint_tbl, regime_changepoint(history_prepped)),
  # tar_target(regime_hmm_tbl, regime_hmm(history_prepped)),  # add when depmixS4 in deps

  # Consensus across methods
  tar_target(
    regime_tbl,
    regime_consensus(
      combine_regime_methods(regime_rollmad_tbl, regime_changepoint_tbl)
    )
  ),

  # Transition detection
  tar_target(regime_transitions_tbl, regime_transitions(regime_tbl)),

  # Wire latest regime into alert summary
  tar_target(
    alert_summary,
    compute_alerts(
      prices_validated, summary_7d, summary_30d, bollinger_7d,
      regime_latest = regime_tbl |> group_by(token) |> slice_max(fetched_at),
      transitions_latest = regime_transitions_tbl |> group_by(token) |> slice_max(fetched_at)
    )
  )
)
```

---

## Dependency additions (when each method is activated)

| Method | Package | Current status |
|--------|---------|----------------|
| Rolling MAD | `slider` | Already in deps |
| HMM | `depmixS4` | Not in deps — add when activated |
| Change-point | `changepoint` | Not in deps — add when activated |
| K-means | base R `kmeans` | Already available |
| GARCH | `rugarch` | Not in deps — DO NOT add (too heavy) |

---

## Implementation phases

1. **Phase R1 (ship first):** Method 1 (rolling MAD) + transition detection.
   Minimal deps, immediate value. Requires ≥30 days of history per token —
   already satisfied after the 365d backfill.

2. **Phase R2:** Add Method 3 (changepoint) and consensus logic.
   Useful for retrospective labelling and explicit regime-change events.

3. **Phase R3:** Add Method 2 (HMM) when we want probabilistic regime
   assignments. Higher complexity, adds `depmixS4`.

4. **Phase R4 (maybe never):** K-means or GARCH — only if the above methods
   are insufficient.

---

## Validation

Each method MUST be tested against synthetic data with known regimes before
being trusted on real data:

```r
# tests/test_regime_detection.R
test_that("regime_rollmad detects injected high-vol regime", {
  # Generate returns with known low/high segments
  set.seed(42)
  low_vol  <- rnorm(60, 0, 0.005)
  high_vol <- rnorm(60, 0, 0.05)
  low_vol_2 <- rnorm(60, 0, 0.005)
  returns <- c(low_vol, high_vol, low_vol_2)
  dates <- seq(
    as.POSIXct("2024-01-01"),
    by = "1 day",
    length.out = length(returns) + 1
  )
  prices <- 100 * cumprod(c(1, exp(returns)))

  synthetic <- tibble(
    token = "TEST",
    price_usd = prices,
    liquidity = NA_real_,
    fetched_at = dates
  )

  result <- regime_rollmad(synthetic)

  # Middle segment should be mostly "high", outer segments mostly "low"
  middle <- result[60:120, ]
  expect_gt(mean(middle$regime_mad == "high", na.rm = TRUE), 0.6)
})
```

---

## Caveats

- Daily data from CoinGecko backfill ≠ 12-hourly live data; regime classifications may differ between historical (daily) and live (12h) portions
- Stablecoin regimes are meaningless (always "low") — exclude USDC, USDT from regime analysis
- Memecoins (BONK, WIF) are always "high" — their regimes are transitions *within* high
- Regime detection is exploratory, not confirmatory (per `statistical-reporting` rule)
