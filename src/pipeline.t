-- crypto_alert_t: Phase 1 pipeline
--
-- Prerequisites: Fetch prices first (outside Nix sandbox — needs network):
--   python scripts/fetch_prices.py
--
-- Architecture: T (read CSV) -> rn (analyse) -> pyn (alert) -> Quarto (report)
-- Nix sandbox has no network access, so data fetch is a pre-step.

p = pipeline {

  -- 1. T: read pre-fetched prices CSV
  --    Written by scripts/fetch_prices.py (run before `t run`)
  prices = node(
    command = read_csv("data/latest_prices.csv", separator = "|"),
    serializer = ^arrow
  )

  -- 1b. T: read accumulated price history (appended by fetch_prices.py)
  history = node(
    command = read_csv("data/price_history.csv", separator = "|"),
    serializer = ^arrow
  )

  -- 2. R: analyse prices with dplyr
  --    Consumes both `prices` (latest snapshot) and `history` (accumulated)
  --    Computes:
  --      - MA-7d, MA-30d (informational, mean-based)
  --      - median-7d + MAD-7d (robust baselines)
  --      - robust_zscore (MAD-based anomaly signal, requires >=4 obs/token)
  --      - depeg_alert (stablecoin check, unchanged)
  --      - trigger_alert (depeg only for now; B5 will add MAD-based triggers)
  analysis = rn(
    command = <{
      library(dplyr)
      library(pointblank)

      # --- Data validation (fail loudly on schema/sanity violations) ---
      prices_agent <- create_agent(prices, tbl_name = "prices") |>
        col_exists(c("token", "source", "price_usd", "fetched_at",
                     "price_change_24h", "liquidity", "block_id")) |>
        col_is_character(c("token", "source", "fetched_at")) |>
        col_is_numeric(c("price_usd", "price_change_24h", "liquidity")) |>
        col_vals_not_null(c("token", "source", "price_usd", "fetched_at")) |>
        col_vals_gt(columns = "price_usd", value = 0) |>
        col_vals_lt(columns = "price_usd", value = 1e6) |>
        rows_distinct(columns = "token") |>
        interrogate()

      if (any(prices_agent$validation_set$warn, na.rm = TRUE) ||
          any(prices_agent$validation_set$stop, na.rm = TRUE)) {
        print(prices_agent)
        stop("pointblank validation failed on `prices` table")
      }

      hist_df <- history |>
        mutate(fetched_at = as.POSIXct(fetched_at, tz = "UTC"))

      ref_time <- if (nrow(hist_df) > 0) max(hist_df$fetched_at) else Sys.time()
      cutoff_7d  <- ref_time - as.difftime(7,  units = "days")
      cutoff_30d <- ref_time - as.difftime(30, units = "days")

      summary_7d <- hist_df |>
        filter(fetched_at >= cutoff_7d) |>
        group_by(token) |>
        summarise(
          ma_7d            = mean(price_usd, na.rm = TRUE),
          median_7d        = median(price_usd, na.rm = TRUE),
          mad_7d           = mad(price_usd, na.rm = TRUE),
          liq_median_7d    = median(liquidity, na.rm = TRUE),
          liq_mad_7d       = mad(liquidity, na.rm = TRUE),
          n_7d             = n(),
          .groups          = "drop"
        )

      summary_30d <- hist_df |>
        filter(fetched_at >= cutoff_30d) |>
        group_by(token) |>
        summarise(
          ma_30d     = mean(price_usd, na.rm = TRUE),
          median_30d = median(price_usd, na.rm = TRUE),
          n_30d      = n(),
          .groups    = "drop"
        )

      # Robust anomaly thresholds
      # Note: with only 4 obs MAD is unreliable (near-zero for low noise).
      # Require >=10 obs (~5 days at 12h cron) AND minimum relative volatility
      # so we don't trigger on trivial movements in a near-flat window.
      MIN_OBS_ROBUST <- 10
      MIN_REL_MAD    <- 0.005  # mad_7d / median_7d must be >= 0.5% of price
      Z_PRICE_ALERT  <- 3.0    # |robust z| above this = price anomaly
      Z_LIQ_DROP     <- 3.0    # liquidity drop in MADs
      LIQ_MIN_PCT    <- 0.50   # OR liquidity drop > 50% from median

      analysis <- prices |>
        left_join(summary_7d,  by = "token") |>
        left_join(summary_30d, by = "token") |>
        mutate(
          # Sufficient history for robust stats?
          have_robust_history = !is.na(n_7d) & n_7d >= MIN_OBS_ROBUST,

          # Relative MAD (exclude near-flat windows where any noise crosses 3σ)
          rel_mad_7d = if_else(
            !is.na(median_7d) & median_7d > 0 & !is.na(mad_7d),
            mad_7d / abs(median_7d),
            NA_real_
          ),
          nontrivial_price_mad = !is.na(rel_mad_7d) & rel_mad_7d >= MIN_REL_MAD,

          # Price anomaly (robust, MAD-based, with both gates)
          robust_zscore = if_else(
            have_robust_history & nontrivial_price_mad & mad_7d > 0,
            abs(price_usd - median_7d) / mad_7d,
            NA_real_
          ),
          price_anomaly = !is.na(robust_zscore) & robust_zscore > Z_PRICE_ALERT,

          # Liquidity drop (MAD-based AND percentage — belt and braces)
          liq_zscore = if_else(
            have_robust_history & !is.na(liq_mad_7d) & liq_mad_7d > 0,
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

          # Depeg check (unchanged)
          is_stablecoin = token %in% c("USDC", "USDT"),
          depeg_alert   = is_stablecoin & abs(price_usd - 1.0) > 0.005,

          # Combined trigger
          trigger_alert = depeg_alert | price_anomaly | liquidity_alert
        )
    }>,
    deserializer = [
      prices:  ^arrow,
      history: ^arrow
    ],
    serializer = ^arrow
  )

  -- 3. Python: format alerts (plain text for Phase 1, Swarms agent in Phase 2)
  alerts = pyn(
    command = <{
import pandas as pd
from datetime import datetime, timezone

triggered = analysis[analysis["trigger_alert"] == True]

if len(triggered) > 0:
    lines = ["ALERT at " + datetime.now(timezone.utc).strftime("%H:%M UTC") + ":"]
    for _, row in triggered.iterrows():
        line = "  {}: USD {:.4f} (depeg: {:.4f})".format(
            row["token"], row["price_usd"], abs(row["price_usd"] - 1.0)
        )
        lines.append(line)
    alerts = "\n".join(lines)
else:
    alerts = "No alerts at " + datetime.now(timezone.utc).strftime("%H:%M UTC") + ". All stable."
    }>,
    deserializer = ^arrow,
    serializer = ^json
  )

  -- 4. Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()
