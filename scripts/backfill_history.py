#!/usr/bin/env python3
"""Backfill 365 days of daily price history from CoinGecko.

Free tier: 5-15 calls/minute, up to 365 days of daily closes via
    /coins/{id}/market_chart?vs_currency=usd&days=365

Produces rows with the same schema as fetch_prices.py so they merge cleanly
into data/price_history.parquet. Dedupes on (token, fetched_at) to avoid
clashes with existing live data.

Usage:
    nix develop --command python3 scripts/backfill_history.py
    nix develop --command python3 scripts/backfill_history.py --days 365
    nix develop --command python3 scripts/backfill_history.py --token SOL

Rate limiting: waits 10s between requests to stay under free tier limits.
"""

import argparse
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pandas as pd


# Mapping: our ticker -> CoinGecko id
# Only tokens that have working CoinGecko ids on the free tier
COINGECKO_IDS = {
    "SOL":     "solana",
    "USDC":    "usd-coin",
    "USDT":    "tether",
    "JUP":     "jupiter-exchange-solana",
    "JTO":     "jito-governance-token",
    "BONK":    "bonk",
    "WIF":     "dogwifcoin",
    "PYTH":    "pyth-network",
    "RENDER":  "render-token",
    "HNT":     "helium",
    "RAY":     "raydium",
    "ORCA":    "orca",
    "mSOL":    "msol",
    "JitoSOL": "jito-staked-sol",
    "DRIFT":   "drift-protocol",
    "KMNO":    "kamino",
}


def fetch_coingecko_history(cg_id, ticker, days=365):
    """Fetch daily closes for the last `days` days."""
    url = "https://api.coingecko.com/api/v3/coins/{}/market_chart".format(cg_id)
    resp = httpx.get(
        url,
        params={"vs_currency": "usd", "days": str(days), "interval": "daily"},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()

    prices = data.get("prices", [])
    if not prices:
        return pd.DataFrame()

    rows = []
    for ts_ms, price in prices:
        fetched_at = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
        rows.append({
            "token": ticker,
            "source": "coingecko_backfill",
            "price_usd": float(price),
            "price_change_24h": None,
            "liquidity": None,
            "block_id": None,
            "fetched_at": fetched_at,
        })
    return pd.DataFrame(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--days", type=int, default=365, help="Lookback days (max 365 on free tier)")
    parser.add_argument("--token", type=str, default=None, help="Backfill a single ticker")
    parser.add_argument("--sleep", type=float, default=10.0, help="Seconds between requests")
    parser.add_argument("--dry-run", action="store_true", help="Don't write to parquet")
    args = parser.parse_args()

    tokens = {args.token: COINGECKO_IDS[args.token]} if args.token else COINGECKO_IDS
    if args.token and args.token not in COINGECKO_IDS:
        print("Unknown ticker: {}".format(args.token), file=sys.stderr)
        print("Known: {}".format(", ".join(COINGECKO_IDS.keys())))
        return 1

    all_rows = []
    for i, (ticker, cg_id) in enumerate(tokens.items(), start=1):
        print("[{}/{}] Fetching {} ({}) ...".format(i, len(tokens), ticker, cg_id))
        try:
            df = fetch_coingecko_history(cg_id, ticker, args.days)
            print("  -> {} rows".format(len(df)))
            all_rows.append(df)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 429:
                print("  -> rate limited, sleeping 60s and retrying ...")
                time.sleep(60)
                try:
                    df = fetch_coingecko_history(cg_id, ticker, args.days)
                    print("  -> {} rows (retry)".format(len(df)))
                    all_rows.append(df)
                except Exception as e2:
                    print("  -> FAILED after retry: {}".format(e2), file=sys.stderr)
            else:
                print("  -> HTTP error: {}".format(e), file=sys.stderr)
        except Exception as e:
            print("  -> error: {}".format(e), file=sys.stderr)

        if i < len(tokens):
            time.sleep(args.sleep)

    if not all_rows:
        print("No data fetched.", file=sys.stderr)
        return 1

    backfill_df = pd.concat(all_rows, ignore_index=True)
    backfill_df["fetched_at"] = pd.to_datetime(backfill_df["fetched_at"], utc=True)
    backfill_df["block_id"] = pd.to_numeric(backfill_df["block_id"], errors="coerce").astype("Int64")
    print("\nTotal backfill rows: {}".format(len(backfill_df)))

    if args.dry_run:
        print("(dry run — not writing)")
        print(backfill_df.head(3))
        print("...")
        print(backfill_df.tail(3))
        return 0

    # Merge into existing history
    history = Path("data/price_history.parquet")
    if history.exists():
        existing = pd.read_parquet(history)
        merged = pd.concat([existing, backfill_df], ignore_index=True)
    else:
        merged = backfill_df

    before = len(merged)
    merged = merged.drop_duplicates(subset=["token", "fetched_at"], keep="last")
    merged = merged.sort_values(["token", "fetched_at"]).reset_index(drop=True)
    after = len(merged)

    merged.to_parquet(history, index=False, compression="zstd")
    print("Wrote {} rows to {} ({} duplicates removed)".format(
        after, history, before - after
    ))
    print("\nPer-token counts:")
    print(merged.groupby("token").size().to_string())

    return 0


if __name__ == "__main__":
    sys.exit(main())
