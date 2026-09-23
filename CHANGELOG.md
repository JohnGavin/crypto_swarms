# Changelog

## 2026-09-23

### Added
- **Regime detection Phase R2: change-point method + consensus voting** (issue #19 P3). `docs/REGIME_DETECTION_PLAN.md`'s phased rollout shipped only Phase R1 (rolling MAD) so far; #19 P3 asks to test whether macro covariates add signal to "regime consensus", but no consensus existed yet -- only a single method. `R/regime_changepoint.R` adds Method 3 (`changepoint::cpt.var()` PELT on log-returns, segments tertile-classified by their own MAD) and `regime_consensus()` (N-method majority vote + `regime_confidence`, written for N methods so a future 3rd vote -- e.g. HMM, Phase R3 -- is a one-line change at the call site). `_targets.R` now drives `regime_latest_tbl`/`regime_shock` off `regime_consensus` instead of the raw Phase R1 `regime_mad`. `regime_latest()` generalised with a `regime_col` param (default unchanged, back-compat with existing Phase R1 callers/tests).
- 16 new tests (`tests/testthat/test-regime-changepoint.R`, 31.25% snapshot ratio) plus `tproject.toml`'s `changepoint` R dependency.
- Verified end-to-end on live data: `t run src/pipeline.t` -> 6/6 nodes built, `alert_summary` target carries real `regime_consensus`/`regime_confidence` values (stablecoins correctly NA/excluded; genuine method-disagreement rows correctly show confidence 0.5, e.g. KMNO, JTO).
- Macro covariates themselves are NOT wired in by this work -- that is the next step now that a consensus exists to test them against, and is separate, not-yet-started work.

- **Progression ladder tracker** (issue #18 gap G9). Report section for the essay's 8-phase ladder (perp yield -> on-chain stocks -> private trading -> institutional lending -> direct issuance -> CBDC corporate finance -> private FX swaps -> looped international fixed income), each row carrying an indicator, status and data source. None of gaps G1-G8 are built yet, so every phase currently reads INDETERMINATE -- shipped anyway (explicit decision) to make the instrumentation gap auditable in the report rather than silently absent. `R/progression_ladder.R`, a new standalone `progression_ladder` T node (additive only, existing nodes untouched), a new report.qmd section, 7 tests (2 snapshots).

### Fixed
- `tproject.toml`'s `[py-dependencies]` never declared `httpx`, even though `flake.nix`'s Python environment has carried it since before this branch (used by `fetch_prices.py`, `swarms_agent.py`, `fetch_nft_floors.py`, `backfill_history.py`, `historical_contract.py`). `flake.nix` is the single source of truth's *output*, not its source -- `tproject.toml` is -- so running `t update` for the `changepoint` dependency above silently regenerated `flake.nix` without `httpx`, which would have broken every Python fetch script's next `nix develop` entry. Declared `httpx` in `tproject.toml` instead of hand-patching `flake.nix`.

### Removed
- **NFT floor-price tracking** (issue #26). NFTs are not of interest; NFT alerts were already disabled 2026-09-23 (the `nft_alerts` node + report section). This removes the rest: the `.github/workflows/scheduled-run.yml` fetch step, `scripts/run.sh`'s call, `scripts/fetch_nft_floors.py`, the `nft_history` T node and `analysis` node's `nft_history` deserializer, `_targets.R`'s six `nft_*` targets, `R/nft_functions.R` + its tests/snapshots, and the NFT path entries in `scripts/ci/check_addresses.py`/`check_secrets.py`. `data/nft_floor_history.parquet` is untracked (`git rm --cached`) -- kept in git history, no longer updated. Verified: `t run src/pipeline.t` -> 6/6 nodes built (down from 7, correctly), rendered report has zero errors/NULLs. Closes the loop with #9.

## 2026-09-22

### Added
- **NFT floor-price anomaly detection** (issue #9). `scripts/fetch_nft_floors.py` has fetched and committed `data/nft_floor_history.parquet` since April, but nothing analysed it. Added the same robust MAD z-score pattern used for token prices, applied to `floor_sol` per collection over a 14-day window (longer than the 7d token default, per `docs/REGIME_DETECTION_PLAN.md`'s noise caveat): `R/nft_functions.R` (`prepare_nft_history`, `compute_nft_window_summary`, `nft_latest_snapshot`, `compute_nft_alerts`), a `nft_alerts` T node in `src/pipeline.t`, and a new "NFT Floor Prices" report section.
- New `nft_alerts` T node is deliberately lightweight (no targets/crew) and deliberately does NOT include `R/analysis_functions.R`: a node whose include list names a file containing the substring "analysis" is wrongly treated by T's dependency inference as depending on the sibling node literally named `analysis`, causing a `readRDS(".../analysis/artifact") : read error`. Reproduced directly; see `R/nft_functions.R`'s header comment. Filing upstream is a follow-up, not done here.
- Not wired into email: per the 2026-09-21 change (severe-day gate), a single collection's floor drop does not meet the "very volatile day" bar. It surfaces in the report only.

### Fixed
- `src/pipeline.t`'s `alerts` pyn step (feeds the report's "Alert Status" section) had the same "every triggered token labelled as a depeg" bug fixed in `scripts/swarms_agent.py` on 2026-09-21, in a separate formatter. `alert_reason()` now names the actual trigger per row (depeg / price anomaly / Bollinger break / liquidity drop / regime shock). Verified live: BONK "volatility regime shock", DRIFT "liquidity drop", KMNO "price anomaly (robust z-score)", USDT "liquidity drop" — none mislabelled "depeg". T-lang bug from the NFT work above filed upstream: [b-rodrigues/tlang#527](https://github.com/b-rodrigues/tlang/issues/527).

## 2026-09-21

### Changed
- **Notifications now need a severe market-wide day.** Per-token triggers (robust z, Bollinger, liquidity, regime) still run and still populate the report, but no longer send email on their own. An email is sent only when the median absolute 24h move of the 12 core tokens is >= 12% (`CRYPTO_SEVERE_MEDIAN_PCT`) or a stablecoin is >= 2% off $1 (`CRYPTO_SEVERE_DEPEG`), at most once per 7 days (`CRYPTO_ALERT_COOLDOWN_DAYS`, derived from `data/price_history.parquet`). Replay over the 284 snapshots since 2026-04-12: 0 emails at 12%, 5 at 8%.
- If the gate cannot be evaluated it says INDETERMINATE and sends nothing; if the cooldown cannot be evaluated a severe alert is still sent.

### Fixed
- Emails called every triggered token "depegged": `stablecoins_triggered` held all triggered tokens. It now holds real stablecoin depegs only; the subject and body carry the actual reason.

### Known
- Alert GitHub issues have failed with 403 since April (the workflow lacks `issues: write`), so only email is sent. Not changed here.

## 2026-04-09 / 2026-04-10

### Completed
- **16 Solana ecosystem tokens** (SOL, mSOL, JitoSOL, JUP, RAY, ORCA, PYTH, RENDER, HNT, JTO, KMNO, DRIFT, BONK, WIF, USDC, USDT)
- **Robust moving averages** (MA-7d, MA-30d, median-7d, MAD-7d) with time-based windowing (not count-based)
- **Price + liquidity anomaly detection** via MAD-based robust z-scores with dual gates (n≥10, rel_MAD≥0.5%)
- **pointblank validation** on pipeline inputs (schema, types, ranges, uniqueness)
- **Robust Bollinger bands** (MAD-based, k=3) — bb_valid=TRUE for all 16 tokens after backfill
- **Phase 2: targets + crew inside rn node** (#1 shipped) — DAG structure, error isolation, crew parallelism
- **Parquet migration** — replaced CSV with zstd-compressed Parquet; added duckplyr to deps
- **365-day CoinGecko backfill** — 5,904 rows (369 per token), all tokens have valid bands
- **Volatility regime detection plan** (#10 raised) — 5 methods, consensus voting, phased rollout
- **OrbStack VM isolation triggers** documented in SECURITY.md
- **NFT floor tracking issue** (#9 raised) for Tensor/Magic Eden APIs

### Failed Approaches
- **WIF false-positive liquidity alert** — CoinGecko backfill has NA liquidity, so MAD of the few live Jupiter observations was near-zero. A 0.2% liquidity change crossed 3σ. Fix: added `n_liq_7d` (non-NA count) and `rel_liq_mad_7d` (relative MAD) gates to match the price gate pattern.
- **DRIFT/HNT false-positive price alerts** — with only 4 observations, MAD was so small that trivial noise crossed 3σ. Fix: raised minimum from 4 to 10 observations + added relative-MAD floor of 0.5%.
- **mSOL CoinGecko ID "marinade-staked-sol"** returned 404. Correct ID is "msol". Rate-limited during diagnosis (429). Fixed and retried.
- **T pipeline `read_csv` with Parquet** — T has no `read_parquet()` primitive. Fix: use `rn` nodes with `include = [...]` to read parquet via arrow inside R.
- **Removed prices/history T-level nodes** initially in Parquet migration, breaking the Quarto report which depended on `read_node("history")`. Fix: restored as `rn` nodes reading parquet with `include`.

### Accuracy / Metrics
- Tokens: 3 → 16 (Solana ecosystem)
- History: 17 rows → 5,904 rows (365 days × 16 tokens)
- Analysis columns: 27 → 34 (added Bollinger, regime-ready, liquidity gates)
- Bollinger bands: all `bb_valid_7d = FALSE` → all `TRUE`
- False positives: 2 (WIF liq, DRIFT/HNT price) → 0 after gate fixes
- Pipeline nodes: 5/5 green
- Open issues: 4 (#1 Phase 3 deferred, #8 private split, #9 NFT, #10 regime)
- Closed issues: 4 (#2 Jupiter v3, #3 history, #4 report, #5 test alert)

### Known Limitations
- CoinGecko backfill is daily resolution; live Jupiter is 12h — regime detection methods need to handle mixed frequencies
- Liquidity anomaly gates are effectively OFF (n_liq < 10) until ~5 days of 12h cron accumulates enough live Jupiter observations
- `targets` metadata doesn't persist across T runs — each build from scratch inside the rn node
- Stablecoin regimes are trivially "low" — should exclude from regime analysis
- `depmixS4` and `changepoint` R packages not yet in deps (regime phases R2, R3)
- GHA `claude -p` won't work (no OAuth on runners) — `CRYPTO_LLM_ANALYSIS=false` in CI

## 2026-04-08 / 2026-04-09

### Completed
- **Plotly range slider chart** replacing ggplot2, 90-day default range (per user UI rule)
- **History dedupe** on `(token, fetched_at)` in `fetch_prices.py`
- **Swarms agent post-step stub** (`scripts/swarms_agent.py`) with dry-run mode
- **GHA scheduled workflow** — cron every 12h, uploads report, commits price history
- **Email transport** via Gmail SMTP (`smtplib`, mirrors `irishbuoys/R/email_summary.R` pattern)
- **GitHub issue transport** via REST API (no `gh` CLI dep, uses `GH_TOKEN`)
- **Security policy** (`SECURITY.md`) — what stays public, wallet guidance, rotation process
- **`.env.example`** template + expanded `.gitignore` for sensitive files
- **Address scanner** (`scripts/ci/check_addresses.py`) — blocks raw Solana/Ethereum addresses not on allowlist
- **Secrets scanner** (`scripts/ci/check_secrets.py`) — detects Anthropic, OpenAI, Google, ElevenLabs, GitHub, AWS, Slack, private keys, Gmail app passwords
- **Pre-commit hook** (`scripts/ci/install-hooks.sh`) runs both scanners
- **GHA runs both scanners** on every push so PRs can't bypass local hooks
- **Claude CLI integration** (`call_claude_cli()`) — uses Max subscription via `claude -p`, zero API cost
- **Packaging plan** (`docs/PACKAGING_PLAN.md`) documented for future private-repo split
- **Issue #8** raised to track future `crypto_swarms_private` sibling repo
- **Analyze alerts helper** (`scripts/analyze_alerts.sh`) for manual/scheduled Claude Code analysis

### Failed Approaches
- **Plotly first attempt rendered twice** — `{python}` auto-display + `{r}` include both emitted the chart. Fix: just `fig` at end of python chunk.
- **`reticulate` used its own Python** (no pandas) in Quarto `{python}` chunks. Fix: set `RETICULATE_PYTHON = Sys.getenv("QUARTO_PYTHON")` in setup chunk.
- **`claude -p` silent exit 1 inside `nix develop`** — Nix puts `/nix/store/...claude-code-2.1.25/bin/claude` ahead of `/opt/homebrew/bin/claude` in PATH. The Nix-bundled claude has no OAuth credentials, so `-p` exits silently. Fix: `_find_claude_binary()` prefers Homebrew's absolute path.
- **Initial diagnosis of `claude -p` "credit too low"** blamed subprocess context. Actual cause: `ANTHROPIC_API_KEY` in `~/.zshenv` line 69 shadowed the Max subscription OAuth. User had to rotate the leaked key (which they accidentally pasted during diagnosis — prompted immediate rotation of all four leaked keys).
- **`env -u ANTHROPIC_API_KEY echo "..." | claude -p`** — `env -u` only affected `echo`, not `claude`. Correct form: `echo "..." | env -u ANTHROPIC_API_KEY claude -p`.

### Accuracy / Metrics
- Pipeline nodes: 5/5 passing (added `history`)
- Report sections: minimal → 4 (alert callout, prices table, depeg analysis, plotly history chart)
- Alert transports: 0 → 3 (email, GH issue, LLM analysis via claude -p)
- Pre-commit scanners: 0 → 2 (addresses, secrets)
- GHA cron runs succeeded: 2 (02:11, 07:16) before cron switched from 6h → 12h
- Issues: #1 (Phase 2/3) + #8 (private split) open; #2/#3/#4 closed with fixes
- Commits in session: 11 (from `b9f7044` packaging docs through `b2cf318` claude -p fix)

### Security Actions Taken
- **Four API keys rotated** after accidental paste during diagnosis: Anthropic, OpenAI, Google, ElevenLabs
- **`ANTHROPIC_API_KEY` commented out** in `~/.zshenv` — `claude -p` now uses Max OAuth
- **Pre-commit secret scanner** prevents recurrence
- **`SECURITY.md`** documents the policy and rotation process

### Known Limitations
- GHA workflow will fail LLM analysis step since GHA runners don't have user's Claude Code OAuth. `CRYPTO_LLM_ANALYSIS` defaults to `false` in the workflow. Manual local runs use the Max subscription.
- Price history in GHA commits to main directly (no PR review for accumulated data)
- Plotly chart in Quarto requires both `reticulate` (R) and `plotly` (Python) — heavier than ggplot2 but gives interactive range slider
- Phase 2 (`targets`/`crew` inside `rn` nodes) still pending — tracked in #1
- Packaging as pip-installable pending — tracked in #8, documented in `docs/PACKAGING_PLAN.md`

## 2026-04-07

### Completed
- **Jupiter API v3** (#2): endpoint was v2 (404), now v3 with `usdPrice`, `priceChange24h`, `liquidity`, `blockId` fields
- **Historical price accumulation** (#3): appends to `data/price_history.csv`; new `history` node in pipeline; dedupe on (token, fetched_at)
- **Richer Quarto report** (#4): alert callout, prices table, depeg analysis, plotly subplot with range slider (5/5 nodes)
- **Plotly range slider** with 90-day default x-range (per user UI rule)
- **Swarms agent post-step stub** (`scripts/swarms_agent.py`): reads pipeline outputs, builds agent context, dry-run by default
- **GHA scheduled workflow** (`.github/workflows/scheduled-run.yml`): cron every 6h, uploads report artifact, commits price history
- **Phase 2 architecture notes** on issue #1: targets+crew caching trade-off, Swarms network options (`__noChroot` vs post-step)
- Dependencies added: `ggplot2`, `jsonlite`, `knitr`, `reticulate` (R); `plotly` (Python)

### Failed Approaches
- Tried `read_node_artifact()` helper function in report.qmd. Failed because T auto-detects dependencies by scanning for literal `read_node("X")` calls — a wrapper function hides the pattern. Fix: call `read_node("X")` directly and assign to a variable (T sed-replaces it with the path string).
- Considered `__noChroot = true` for Swarms network access. No current T flag to set it on generated derivations. Deferred as future upstream feature request.
- `{python}` chunks in Quarto require `reticulate`, AND reticulate uses its own Python by default (no pandas). Fix: set `RETICULATE_PYTHON = Sys.getenv("QUARTO_PYTHON")` in setup chunk to point at Nix py-env.
- First plotly chart rendered twice — once from `{python}` chunk auto-display and once from `{r}` `cat()` include. Fix: just `fig` at end of python chunk, no separate include.

### Accuracy / Metrics
- Pipeline nodes: 4 → 5 (added `history`)
- Report sections: 3 (paths only) → 4 (alert, prices table, analysis, history chart)
- GitHub issues: 1 open → 1 open + 3 closed (all Phase 1 tasks done)

### Known Limitations
- Swarms SDK not actually wired (stub only). Need API key + uncomment block in `swarms_agent.py`.
- `crew` + `targets` inside `rn` nodes breaks Nix hermeticity for caching (Phase 2)
- GHA workflow commits to main directly on scheduled runs (no PR review for accumulated history)
- No alerting transport (email, Slack, webhook) — Swarms agent just prints

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
