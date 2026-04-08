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

## Sensitive Files Policy

**Store outside the repo, not just gitignored.** `.gitignore` is a blacklist
and can be bypassed by `git add -f`, accidental commits, or files that were
committed before being added to the ignore list.

For anything truly sensitive (wallet info, tax CSVs, portfolio data):

```bash
mkdir -p ~/.config/crypto_swarms
chmod 700 ~/.config/crypto_swarms
```

Then read from env vars pointing at that directory. Code cannot accidentally
commit what isn't inside the worktree.

`.gitignore` entries for `data/private/`, `.env`, etc. are belt-and-braces
defence — they catch accidents but should not be the only line of defence.

## Future Repo Split

When strategy logic or personal data enters the picture, split into:

- `crypto_swarms` (this repo, public) — infrastructure, generic checks, transports
- `crypto_swarms_private` (future, private) — strategy, wallets, recipients, positions

### How the two repos relate

| Approach | Recommended? | Notes |
|----------|--------------|-------|
| Package the public repo (PyPI / r-universe) | Yes | Private repo imports as a dependency |
| Git submodule | No | Painful UX, CI coupling |
| Path dependency (`pip install -e ../crypto_swarms`) | OK for dev | Not reproducible across machines |
| Fork and rebase | No | Hard to maintain |

## Wallet Addresses

Wallet addresses on public blockchains are always public — they're identifiers,
not secrets. What's private is the **private key** that controls them.

- **Watch-only usage** (reading balances, no signing) is safe code-wise
- But committing an address ties your GitHub identity to all on-chain activity
  for that address, **forever**, via chain-analysis tools
- Prefer fresh addresses never funded from your main wallet, or hash/truncate
  any addresses in committed code

## Getting an Anthropic API Key

A Claude.ai subscription (Pro/Max/Team) does NOT include API access.
They are billed separately:

| Product | What it covers | Where |
|---------|---------------|-------|
| Claude.ai subscription | Web/desktop/mobile chat | claude.ai/upgrade |
| Anthropic API | Programmatic calls from code | console.anthropic.com |

For this project's Swarms agent, add billing at console.anthropic.com, create
an API key (`sk-ant-...`), and add it as the `ANTHROPIC_API_KEY` GH Actions
secret.

Free alternatives for the LLM call:
- **Groq** (free tier, Llama models)
- **Gemini API** (generous free tier)
- **Ollama** (local, free, runs on Apple Silicon)
