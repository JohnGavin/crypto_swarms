# crypto_alert_t

Crypto price alerts: Python fetches via Solana/CoinGecko APIs, R analyses with dplyr, Python formats alerts.

## Pipeline

1. `scripts/fetch_prices.py` — fetch prices (outside Nix sandbox)
2. `t run src/pipeline.t` — analyse + alert (sandboxed)
3. Results in `pipeline-output/alerts/artifact`
