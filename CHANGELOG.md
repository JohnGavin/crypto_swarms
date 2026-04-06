# Changelog

## 2026-04-06

### Completed
- Phase 1 crypto_alert_t pipeline: T(read_csv) → R(dplyr depeg check) → Python(format alerts) → Quarto report
- 4/4 nodes building successfully
- CoinGecko free API for price data (Jupiter as primary, falls back to CoinGecko)
- `scripts/run.sh` convenience wrapper: fetch + build + show results
- `help/docs.json` and `docs/index.md` suppress T warnings, `t doctor` passes
- GitHub repo: JohnGavin/crypto_swarms
- Phase 2/3 issue raised: #1

### Failed Approaches
- Jupiter API v2 (`api.jup.ag/price/v2`) returns 404 on all endpoints despite docs saying keyless access at 0.5 RPS. Possibly geo-restricted or endpoint moved. Workaround: CoinGecko fallback. Jupiter code is in place and will auto-switch when it resolves.
- Python f-strings with `$` inside T `pyn` nodes fail: Nix interprets `${...}` as string interpolation in generated `pipeline.nix`. Workaround: use `.format()` instead of f-strings when the string contains `$`.
- T's `read_csv()` produces native T serialization, not Arrow IPC. Downstream `rn` nodes with `deserializer = ^arrow` fail with "Not a Feather V1 or Arrow IPC file". Fix: wrap in `node(command = read_csv(...), serializer = ^arrow)`.
- Quarto `_extensions/tlang/` at project root not found during Nix sandbox build. Nix copies `src/` into the build dir, so extension must be at `src/_extensions/tlang/` (relative to the `.qmd` file).
- Network calls (httpx, API fetches) cannot run inside T pipeline nodes — Nix sandbox has no network. Data fetch must be a pre-step outside the pipeline.

### Known Limitations
- Jupiter API not working (404) — may need API key or different endpoint
- Quarto report is minimal (just prints artifact paths) — needs richer formatting
- No historical price storage — each run overwrites `data/latest_prices.csv`
- No scheduling/cron — `run.sh` is manual
- `swarms` Python SDK not yet integrated (Phase 2)
- No targets/crew inside R nodes yet (Phase 2)
