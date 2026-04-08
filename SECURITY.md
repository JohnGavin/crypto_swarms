# Security Policy

## Public Repository — What Stays Out

This is a **public** repository. The following must NEVER be committed:

| Category | Examples | Where they belong |
|----------|----------|-------------------|
| Credentials | API keys, passwords, tokens | `.env` (gitignored) or GH Actions secrets |
| Wallet material | Private keys, seed phrases, mnemonics | Hardware wallet / OS keychain only — never in git |
| Exchange API keys | Binance, Coinbase, Kraken | GH Actions secrets, read-only scope where possible |
| RPC endpoint keys | Helius, QuickNode, Triton | GH Actions secrets |
| Personal financial data | Portfolio CSVs, trade history, PnL | `data/private/` (gitignored) |
| Real wallet addresses | Addresses tied to your identity | Consider whether the project truly needs them |
| Recipient lists | Alert email recipients | Env vars only, not hardcoded |
| Proprietary strategy | Alpha-generating logic | Private sibling repo |

## Public-Safe (intentionally committed)

- Pipeline code (`src/pipeline.t`, R/Python nodes)
- Threshold constants (e.g. `0.005` depeg)
- Public token mint addresses (SOL, USDC, USDT are public knowledge)
- Accumulated `price_history.csv` (public market data — GHA commits this)
- Quarto report template
- GHA workflow structure
- Architecture docs, CHANGELOG

## GitHub Actions Secrets

Secrets are encrypted by GitHub and:
- Never exposed in logs (GHA auto-redacts)
- Never passed to workflow runs from PR forks
- Only accessible via `${{ secrets.NAME }}` in the workflow file

Current secrets expected:
- `GMAIL_USERNAME`, `GMAIL_APP_PASSWORD` — email transport
- `GITHUB_TOKEN` — auto-provided, creates issues
- Future: `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` for Swarms LLM

## If a Secret Leaks

1. **Rotate immediately** at the source (Gmail app password, API provider, etc.)
2. Remove from git history with [`git filter-repo`](https://github.com/newren/git-filter-repo)
3. Force-push (requires admin confirmation — contact maintainer)
4. Audit downstream: any logs, Cachix, GHA artifacts that may contain it

## Reporting

Security issues: open a **private security advisory** via GitHub, not a public issue:
https://github.com/JohnGavin/crypto_swarms/security/advisories/new

## Future Repo Split

When strategy logic or personal data enters the picture, split into:

- `crypto_swarms` (this repo, public) — infrastructure, generic checks, transports
- `crypto_swarms_private` (future, private) — strategy, wallets, recipients, positions
