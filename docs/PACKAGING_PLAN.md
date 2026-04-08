# Packaging Plan — Making `crypto_swarms` Installable

## Why

When personal strategy/wallet logic is added, a private sibling repo
(`crypto_swarms_private`) will need to depend on this one. The cleanest way
is to make this repo a proper Python package that the private repo imports,
rather than copy-pasting code or using git submodules.

Tracked in issue #8.

## Triggers (do this when ANY becomes true)

- [ ] About to write real strategy logic that should not be public
- [ ] Another project wants to reuse the fetch/analyse/alert pipeline
- [ ] Multiple people need to run the same pipeline on different configs

## What gets packaged

Only the Python side. The T pipeline itself stays as source files
(`src/pipeline.t`, `tproject.toml`, `flake.nix`) — T is not Python, and
`t run` is the entry point, not an importable module.

Packaged Python modules:

| Module | Source | Exports |
|--------|--------|---------|
| `crypto_swarms.fetch` | `scripts/fetch_prices.py` | `fetch_jupiter()`, `fetch_coingecko()`, `write_history()` |
| `crypto_swarms.alerts` | `scripts/swarms_agent.py` | `build_agent_context()`, `send_email_alert()`, `create_github_issue()`, formatters |
| `crypto_swarms.ci` | `scripts/ci/check_addresses.py` | `scan_file()`, `is_allowed()` |

The T/Quarto side (pipeline.t, report.qmd, flake.nix) is **not** importable;
consumers either:
- Copy the T project structure and adapt
- Use the Python modules and write their own orchestration
- Vendor the T files via a release tarball

## Steps (when triggered)

### Phase A: Restructure into package layout

```
crypto_swarms/
├── pyproject.toml          (new)
├── src/
│   └── crypto_swarms/      (new Python package dir)
│       ├── __init__.py
│       ├── fetch.py        (was scripts/fetch_prices.py, refactored)
│       ├── alerts.py       (was scripts/swarms_agent.py, refactored)
│       └── ci/
│           ├── __init__.py
│           └── check_addresses.py
├── src/pipeline.t          (unchanged)
├── src/report.qmd          (unchanged)
├── scripts/                (thin wrappers that call the package)
│   ├── fetch_prices.py     -> `python -m crypto_swarms.fetch`
│   ├── swarms_agent.py     -> `python -m crypto_swarms.alerts`
│   └── ci/check_addresses.py -> `python -m crypto_swarms.ci.check_addresses`
└── tests/
    └── test_*.py           (new, unit tests for importable API)
```

**Note:** the current `src/` dir already holds T source (`pipeline.t`,
`report.qmd`). Python convention is also `src/` layout. They coexist:
`src/crypto_swarms/*.py` is the Python package, `src/pipeline.t` is T source.

### Phase B: Minimal pyproject.toml

```toml
[project]
name = "crypto_swarms"
version = "0.1.0"
description = "Polyglot crypto monitoring pipeline — Python fetch + R analysis + alerts"
readme = "README.md"
license = { text = "MIT" }
authors = [{ name = "John Gavin" }]
requires-python = ">=3.10"
dependencies = [
    "httpx>=0.25",
    "pandas>=2.0",
    "pyarrow>=14",
]

[project.optional-dependencies]
alerts = []  # only stdlib smtplib + httpx
plotly = ["plotly>=5"]
dev = ["pytest", "ruff"]

[project.scripts]
crypto-swarms-fetch = "crypto_swarms.fetch:main"
crypto-swarms-alerts = "crypto_swarms.alerts:main"
crypto-swarms-check-addrs = "crypto_swarms.ci.check_addresses:main"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/crypto_swarms"]
```

### Phase C: Refactor scripts into modules

- Move `scripts/fetch_prices.py` body into `src/crypto_swarms/fetch.py`
- Add a `main()` entry point that gets called by both `__main__` block
  and the old `scripts/fetch_prices.py` wrapper
- Same for `swarms_agent.py` → `src/crypto_swarms/alerts.py`
- Add type hints where useful
- Add unit tests under `tests/`

### Phase D: Publish

Three options, ranked:

1. **Install-from-git (zero infra)** — private repo does:
   ```bash
   pip install "crypto_swarms @ git+https://github.com/JohnGavin/crypto_swarms@v0.1.0"
   ```
   Pinned by tag. No PyPI account needed. Works today.

2. **PyPI (standard)** — `uv publish` or `twine upload`. Requires a PyPI
   account and token. Anyone can then `pip install crypto_swarms`.
   Appropriate when the project is stable and intended for others.

3. **GitHub Packages (self-hosted)** — `gh` + `twine` to GitHub's package
   registry. Good if you want to restrict installs to authenticated GH users.

**Recommendation:** start with #1 (install-from-git). Migrate to #2 only if
other people want it.

### Phase E: Update private sibling to consume

```toml
# crypto_swarms_private/pyproject.toml
dependencies = [
    "crypto_swarms @ git+https://github.com/JohnGavin/crypto_swarms@main",
    # private-only deps here
]
```

```python
# crypto_swarms_private/src/crypto_swarms_private/__init__.py
from crypto_swarms.fetch import fetch_jupiter
from crypto_swarms.alerts import build_agent_context, send_email_alert

# Private strategy logic here
def my_proprietary_signal(prices):
    ...
```

## What does NOT need to happen

- Publishing T itself to any registry (T manages its own deps via tproject.toml)
- R packaging (the R code lives inside `pipeline.t` as rn nodes, not as an R package)
- Changing the Nix flake (it keeps building the whole repo as one unit)

## Acceptance criteria

- [ ] `pip install -e .` from a clone produces an importable `crypto_swarms` module
- [ ] Existing `scripts/*.py` wrappers still work unchanged
- [ ] `nix develop --command bash scripts/run.sh` still produces the same output
- [ ] Unit tests pass: `pytest tests/`
- [ ] Pre-commit hook still runs check_addresses.py
- [ ] A second repo can `pip install git+https://...` and import the modules

## Effort estimate

~half a day for Phase A-C, another ~hour each for D and E. Trivial compared
to rewriting in a different language or copy-pasting between two repos.
