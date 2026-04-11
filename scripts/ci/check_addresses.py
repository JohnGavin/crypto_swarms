#!/usr/bin/env python3
"""Pre-commit check: ban raw wallet addresses in committed code.

Solana addresses are base58, 32-44 chars. Ethereum addresses are 0x + 40 hex.
This check blocks commits that add full addresses to source files.

An address is allowed ONLY if:
  1. It's on the allowlist below (e.g. well-known stablecoin mints)
  2. It's hashed: sha256(address)[:12]
  3. It's truncated: first4...last4 format

Usage:
    python3 scripts/ci/check_addresses.py [file1] [file2] ...
    # No args = scan staged files
    git diff --cached --name-only | xargs python3 scripts/ci/check_addresses.py

Exit code 1 if violations found.
"""

import os
import re
import subprocess
import sys
from pathlib import Path


# Regex patterns
SOLANA_RE = re.compile(r"\b[1-9A-HJ-NP-Za-km-z]{32,44}\b")  # base58, no 0OIl
ETH_RE = re.compile(r"\b0x[a-fA-F0-9]{40}\b")

# Allowlist: well-known public addresses that are safe to commit.
# These are SPL token MINT addresses and Ethereum contract addresses — public knowledge,
# not user wallets. Add new tokens here when expanding the tracked set.
ALLOWLIST = {
    # Solana SPL token mints (same as JUPITER_TOKENS in fetch_prices.py)
    "So11111111111111111111111111111111111111112",         # Wrapped SOL
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",     # USDC
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",      # USDT
    "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN",       # JUP
    "jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL",       # JTO
    "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263",     # BONK
    "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm",     # WIF
    "HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3",      # PYTH
    "rndrizKT3MK1iimdxRdWabcF7Zg7AR5T4nud4EkHBof",       # RENDER
    "hntyVP6YFm1Hg25TN9WGLqM12b8TQmcknKrdu1oxWux",      # HNT
    "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R",     # RAY
    "orcaEKTdK7LKz57vaAYr9QeNsVEPfiu6QeMU1kektZE",      # ORCA
    "mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So",      # mSOL
    "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn",     # JitoSOL
    "DriFtupJYLTosbwoN8koMbEYSx54aFAVLddWsbksjwg7",      # DRIFT
    "KMNo3nJsBXfcpJTVhZcXLW7RmTwTt4GVFE7suUBo9sS",      # KMNO
    # Ethereum contract addresses (for reference/comparison)
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",        # USDC on mainnet
    "0xdac17f958d2ee523a2206206994597c13d831ec7",        # USDT on mainnet
}

# Files/dirs to skip (generated, vendored, or deliberately contain examples)
SKIP_PATTERNS = [
    "_pipeline/",
    "pipeline-output/",
    "_extensions/",
    ".git/",
    "data/price_history.csv",
    "data/latest_prices.csv",
    "scripts/ci/check_addresses.py",  # this file, which mentions them
    "scripts/ci/check_secrets.py",     # this file, which mentions key patterns
    "scripts/ci/install-hooks.sh",     # example test address in help text
    "tests/test_ci_checks.py",         # test fixtures with fake addresses
    "CHANGELOG.md",                    # may mention old patterns
]


def should_skip(path):
    path_str = str(path)
    return any(pat in path_str for pat in SKIP_PATTERNS)


def is_allowed(address):
    return address in ALLOWLIST


def scan_file(path):
    """Return list of (line_no, address, kind) tuples."""
    try:
        content = Path(path).read_text(errors="replace")
    except (IsADirectoryError, FileNotFoundError, PermissionError):
        return []

    violations = []
    for i, line in enumerate(content.splitlines(), start=1):
        # Skip obvious comments that reference hashed/truncated patterns
        if "hashed" in line.lower() or "truncat" in line.lower():
            continue

        for match in SOLANA_RE.finditer(line):
            addr = match.group(0)
            if not is_allowed(addr):
                violations.append((i, addr, "solana"))

        for match in ETH_RE.finditer(line):
            addr = match.group(0)
            if not is_allowed(addr.lower()):
                violations.append((i, addr, "eth"))

    return violations


def get_staged_files():
    """Return files staged for commit."""
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        return []
    return [f for f in result.stdout.splitlines() if f]


def main():
    files = sys.argv[1:]
    if not files:
        files = get_staged_files()

    if not files:
        print("[check_addresses] No files to scan.")
        return 0

    total_violations = 0
    for f in files:
        if should_skip(f):
            continue
        if not Path(f).exists():
            continue

        violations = scan_file(f)
        if violations:
            total_violations += len(violations)
            print("\n{}:".format(f))
            for line_no, addr, kind in violations:
                # Show truncated to avoid echoing full address in CI logs
                truncated = "{}...{}".format(addr[:4], addr[-4:])
                print("  line {}: {} address {} (not in allowlist)".format(
                    line_no, kind, truncated
                ))

    if total_violations > 0:
        print("\n" + "=" * 60)
        print("BLOCKED: {} wallet address(es) found in staged files.".format(total_violations))
        print("")
        print("If this is a public mint/contract, add to ALLOWLIST in")
        print("scripts/ci/check_addresses.py.")
        print("")
        print("If it's a user wallet, you have three options:")
        print("  1. Remove it entirely — store in ~/.config/crypto_swarms/")
        print("  2. Hash it:      sha256(address)[:12]")
        print("  3. Truncate it:  first4...last4")
        print("=" * 60)
        return 1

    print("[check_addresses] OK ({} file(s) scanned)".format(len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
