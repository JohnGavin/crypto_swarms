#!/usr/bin/env python3
"""Fetch token prices and write to data/latest_prices.csv + append to data/price_history.csv.

Tries Jupiter API v3 (Solana-native, keyless 0.5 RPS) first,
falls back to CoinGecko (free, no auth).

Run OUTSIDE the T pipeline (before `t run`), because Nix sandbox has no network.

Usage:
    nix develop --command python3 scripts/fetch_prices.py
"""

import httpx
import pandas as pd
from datetime import datetime, timezone
from pathlib import Path

# Jupiter: Solana ecosystem tokens (mint addresses)
# Per https://dev.jup.ag/docs/ — keyless, 0.5 RPS, v3 endpoint, up to 50 ids/req
# Grouped by category for readability.
JUPITER_TOKENS = {
    # Stablecoins (depeg monitoring targets)
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": "USDC",
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": "USDT",

    # Native / liquid staked SOL
    "So11111111111111111111111111111111111111112":  "SOL",
    "mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So":  "mSOL",
    "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn": "JitoSOL",

    # DEX / liquidity protocol tokens
    "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN":  "JUP",
    "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R": "RAY",
    "orcaEKTdK7LKz57vaAYr9QeNsVEPfiu6QeMU1kektZE":  "ORCA",

    # Infrastructure / DePIN
    "HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3": "PYTH",
    "rndrizKT3MK1iimdxRdWabcF7Zg7AR5T4nud4EkHBof":  "RENDER",
    "hntyVP6YFm1Hg25TN9WGLqM12b8TQmcknKrdu1oxWux":  "HNT",

    # Liquid staking / lending
    "jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL":  "JTO",
    "KMNo3nJsBXfcpJTVhZcXLW7RmTwTt4GVFE7suUBo9sS":  "KMNO",
    "DriFtupJYLTosbwoN8koMbEYSx54aFAVLddWsbksjwg7": "DRIFT",

    # Memes (included for signal/noise analysis)
    "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263": "BONK",
    "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm": "WIF",
}

# CoinGecko: fallback IDs (minimal set, degraded mode only)
# Only covers stablecoins + SOL since most Solana tokens aren't on CG free tier.
COINGECKO_TOKENS = {
    "solana": "SOL",
    "usd-coin": "USDC",
    "tether": "USDT",
}


def fetch_jupiter():
    """Fetch from Jupiter Price API v3 (keyless, 0.5 RPS)."""
    resp = httpx.get(
        "https://api.jup.ag/price/v3",
        params={"ids": ",".join(JUPITER_TOKENS.keys())},
        timeout=30,
    )
    resp.raise_for_status()
    # v3 response shape: {mint: {usdPrice, blockId, decimals, priceChange24h, liquidity, createdAt}}
    data = resp.json()
    if not data:
        raise ValueError("Jupiter returned empty data")

    now = datetime.now(timezone.utc).isoformat()
    rows = []
    for mint, info in data.items():
        rows.append({
            "token": JUPITER_TOKENS.get(mint, mint[:8]),
            "source": "jupiter",
            "price_usd": float(info["usdPrice"]),
            "price_change_24h": info.get("priceChange24h"),
            "liquidity": info.get("liquidity"),
            "block_id": info.get("blockId"),
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
            "price_change_24h": None,
            "liquidity": None,
            "block_id": None,
            "fetched_at": now,
        })
    return pd.DataFrame(rows)


# Try Jupiter first, fall back to CoinGecko
try:
    df = fetch_jupiter()
    print("Source: Jupiter API v3")
except Exception as e:
    print("Jupiter failed ({}), falling back to CoinGecko".format(e))
    df = fetch_coingecko()
    print("Source: CoinGecko API")

# Normalize dtypes for Parquet stability (nullable types for Jupiter-only columns)
df["fetched_at"] = pd.to_datetime(df["fetched_at"], utc=True)
for col in ("price_change_24h", "liquidity"):
    df[col] = pd.to_numeric(df[col], errors="coerce")
df["block_id"] = pd.to_numeric(df["block_id"], errors="coerce").astype("Int64")

data_dir = Path("data")
data_dir.mkdir(exist_ok=True)

# Write latest snapshot (small, overwritten each run)
latest = data_dir / "latest_prices.parquet"
df.to_parquet(latest, index=False, compression="zstd")
print("Wrote {} rows to {}".format(len(df), latest))

# Append to history Parquet (read-append-dedupe-write: fine at this scale)
history = data_dir / "price_history.parquet"
if history.exists():
    hist_df = pd.read_parquet(history)
    hist_df = pd.concat([hist_df, df], ignore_index=True)
else:
    hist_df = df.copy()

before = len(hist_df)
hist_df = hist_df.drop_duplicates(subset=["token", "fetched_at"], keep="last")
hist_df = hist_df.sort_values(["token", "fetched_at"]).reset_index(drop=True)
after = len(hist_df)

hist_df.to_parquet(history, index=False, compression="zstd")
if before != after:
    print("History: {} rows ({} duplicates removed)".format(after, before - after))
else:
    print("History: {} total rows in {}".format(after, history))

print(df.to_string(index=False))
