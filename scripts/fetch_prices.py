#!/usr/bin/env python3
"""Fetch token prices and write to data/latest_prices.csv.

Tries Jupiter API (Solana-native, keyless 0.5 RPS) first,
falls back to CoinGecko (free, no auth).

Run OUTSIDE the T pipeline (before `t run`), because Nix sandbox has no network.

Usage:
    python scripts/fetch_prices.py
    # or from nix shell:
    nix develop --command python3 scripts/fetch_prices.py
"""

import httpx
import pandas as pd
from datetime import datetime, timezone
from pathlib import Path

# Jupiter: Solana mint addresses
# Per https://dev.jup.ag/docs/portal/setup — keyless, 0.5 RPS
JUPITER_TOKENS = {
    "So11111111111111111111111111111111111111112": "SOL",
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": "USDC",
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": "USDT",
}

# CoinGecko: fallback IDs
COINGECKO_TOKENS = {
    "solana": "SOL",
    "usd-coin": "USDC",
    "tether": "USDT",
}


def fetch_jupiter():
    """Fetch from Jupiter Price API v2 (keyless, 0.5 RPS)."""
    resp = httpx.get(
        "https://api.jup.ag/price/v2",
        params={"ids": ",".join(JUPITER_TOKENS.keys())},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json().get("data", {})
    if not data:
        raise ValueError("Jupiter returned empty data")

    now = datetime.now(timezone.utc).isoformat()
    rows = []
    for mint, info in data.items():
        rows.append({
            "token": JUPITER_TOKENS.get(mint, mint[:8]),
            "source": "jupiter",
            "price_usd": float(info["price"]),
            "fetched_at": now,
        })
    return pd.DataFrame(rows)


def fetch_coingecko():
    """Fetch from CoinGecko free API (no auth)."""
    resp = httpx.get(
        "https://api.coingecko.com/api/v3/simple/price",
        params={"ids": ",".join(COINGECKO_TOKENS.keys()), "vs_currencies": "usd"},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()

    now = datetime.now(timezone.utc).isoformat()
    rows = []
    for cg_id, ticker in COINGECKO_TOKENS.items():
        rows.append({
            "token": ticker,
            "source": "coingecko",
            "price_usd": data[cg_id]["usd"],
            "fetched_at": now,
        })
    return pd.DataFrame(rows)


# Try Jupiter first, fall back to CoinGecko
try:
    df = fetch_jupiter()
    print("Source: Jupiter API")
except Exception as e:
    print("Jupiter failed ({}), falling back to CoinGecko".format(e))
    df = fetch_coingecko()
    print("Source: CoinGecko API")

out = Path("data/latest_prices.csv")
out.parent.mkdir(exist_ok=True)
df.to_csv(out, index=False, sep="|")
print("Wrote {} rows to {}".format(len(df), out))
print(df.to_string(index=False))
