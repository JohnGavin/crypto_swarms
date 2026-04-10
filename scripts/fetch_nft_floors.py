#!/usr/bin/env python3
"""Fetch Solana NFT collection floor prices from Magic Eden.

Magic Eden v2 API is public (no auth needed) with rate limits.
Floors are in lamports (1 SOL = 1e9 lamports).

Writes to data/nft_floor_history.parquet with same schema pattern as token prices.

Usage:
    nix develop --command python3 scripts/fetch_nft_floors.py
"""

import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pandas as pd

# Major Solana NFT collections
# slug -> display name
COLLECTIONS = {
    "mad_lads": "Mad Lads",
    "solana_monkey_business": "SMB",
    "claynosaurz": "Claynosaurz",
    "tensorians": "Tensorians",
    "lifinity_flares": "Lifinity Flares",
    "okay_bears": "Okay Bears",
    "famous_fox_federation": "Famous Fox",
}

LAMPORTS_PER_SOL = 1e9


def fetch_collection_stats(slug):
    """Fetch floor price + volume from Magic Eden v2."""
    url = "https://api-mainnet.magiceden.dev/v2/collections/{}/stats".format(slug)
    resp = httpx.get(url, timeout=30)
    resp.raise_for_status()
    return resp.json()


def main():
    rows = []
    now = datetime.now(timezone.utc)

    for i, (slug, name) in enumerate(COLLECTIONS.items(), start=1):
        print("[{}/{}] {} ({}) ...".format(i, len(COLLECTIONS), name, slug), end=" ")
        try:
            stats = fetch_collection_stats(slug)
            floor_lamports = stats.get("floorPrice", 0)
            floor_sol = floor_lamports / LAMPORTS_PER_SOL if floor_lamports else None
            listed = stats.get("listedCount", 0)
            vol_all = stats.get("volumeAll", 0)
            vol_sol = vol_all / LAMPORTS_PER_SOL if vol_all else None
            avg_24h = stats.get("avgPrice24hr", 0)
            avg_sol = avg_24h / LAMPORTS_PER_SOL if avg_24h else None

            rows.append({
                "collection": name,
                "slug": slug,
                "floor_sol": floor_sol,
                "listed_count": listed,
                "avg_price_24h_sol": avg_sol,
                "volume_all_sol": vol_sol,
                "fetched_at": now,
            })
            print("floor={:.2f} SOL, listed={}".format(floor_sol or 0, listed))
        except Exception as e:
            print("FAILED: {}".format(e))

        if i < len(COLLECTIONS):
            time.sleep(2)  # respect rate limits

    if not rows:
        print("No data fetched.")
        return

    df = pd.DataFrame(rows)
    df["fetched_at"] = pd.to_datetime(df["fetched_at"], utc=True)

    data_dir = Path("data")
    data_dir.mkdir(exist_ok=True)

    # Append to history
    history = data_dir / "nft_floor_history.parquet"
    if history.exists():
        existing = pd.read_parquet(history)
        merged = pd.concat([existing, df], ignore_index=True)
    else:
        merged = df.copy()

    merged = merged.drop_duplicates(subset=["collection", "fetched_at"], keep="last")
    merged = merged.sort_values(["collection", "fetched_at"]).reset_index(drop=True)
    merged.to_parquet(history, index=False, compression="zstd")
    print("\nWrote {} rows ({} total history) to {}".format(len(df), len(merged), history))


if __name__ == "__main__":
    main()
