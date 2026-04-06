#!/usr/bin/env python3
"""Fetch token prices from CoinGecko (free, no auth) and write to data/latest_prices.csv.

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

TOKENS = {
    "solana": "SOL",
    "usd-coin": "USDC",
    "tether": "USDT",
}

resp = httpx.get(
    "https://api.coingecko.com/api/v3/simple/price",
    params={"ids": ",".join(TOKENS.keys()), "vs_currencies": "usd"},
    timeout=30,
)
resp.raise_for_status()
data = resp.json()

rows = []
now = datetime.now(timezone.utc).isoformat()
for cg_id, ticker in TOKENS.items():
    rows.append({
        "token": ticker,
        "coingecko_id": cg_id,
        "price_usd": data[cg_id]["usd"],
        "fetched_at": now,
    })

df = pd.DataFrame(rows)
out = Path("data/latest_prices.csv")
out.parent.mkdir(exist_ok=True)
df.to_csv(out, index=False, sep="|")
print(f"Wrote {len(df)} rows to {out}")
print(df.to_string(index=False))
