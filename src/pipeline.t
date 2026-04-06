-- crypto_alert_t: Phase 1 pipeline
--
-- Architecture: pyn (fetch) -> rn (analyse) -> pyn (alert) -> Quarto (report)
-- Data flows via Arrow serialization between nodes. No intermediate files.

p = pipeline {

  -- 1. Python: fetch token prices from Jupiter aggregator API
  --    Output: pandas DataFrame with columns [token, price_usd, fetched_at]
  prices = pyn(
    command = <{
import httpx
import pandas as pd
from datetime import datetime, timezone

# SOL and common SPL tokens
TOKEN_IDS = {
    "So11111111111111111111111111111111111111112": "SOL",
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": "USDC",
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": "USDT",
}

resp = httpx.get(
    "https://api.jup.ag/price/v2",
    params={"ids": ",".join(TOKEN_IDS.keys())},
    timeout=30,
)
resp.raise_for_status()
data = resp.json().get("data", {})

rows = []
now = datetime.now(timezone.utc).isoformat()
for mint, info in data.items():
    rows.append({
        "token": TOKEN_IDS.get(mint, mint[:8]),
        "mint": mint,
        "price_usd": float(info["price"]),
        "fetched_at": now,
    })

prices = pd.DataFrame(rows)
    }>,
    serializer = ^arrow
  )

  -- 2. R: analyse prices with dplyr
  --    Receives `prices` as an Arrow table (auto-deserialized)
  --    Computes summary stats and simple alert triggers
  analysis = rn(
    command = <{
      library(dplyr)

      analysis <- prices |>
        mutate(
          # Simple alert thresholds for Phase 1
          # Phase 2 will add moving averages via slider + targets caching
          is_stablecoin = token %in% c("USDC", "USDT"),
          depeg_alert = is_stablecoin & abs(price_usd - 1.0) > 0.005,
          trigger_alert = depeg_alert  # Extend in Phase 2
        )
    }>,
    deserializer = ^arrow,
    serializer = ^arrow
  )

  -- 3. Python: format alerts (plain text for Phase 1, Swarms agent in Phase 2)
  alerts = pyn(
    command = <{
import pandas as pd
from datetime import datetime, timezone

triggered = analysis[analysis["trigger_alert"] == True]

if len(triggered) > 0:
    lines = [f"ALERT at {datetime.now(timezone.utc).strftime('%H:%M UTC')}:"]
    for _, row in triggered.iterrows():
        lines.append(
            f"  {row['token']}: ${row['price_usd']:.4f} "
            f"(depeg: {abs(row['price_usd'] - 1.0):.4f})"
        )
    alerts = "\n".join(lines)
else:
    alerts = f"No alerts at {datetime.now(timezone.utc).strftime('%H:%M UTC')}. All stable."
    }>,
    deserializer = ^arrow,
    serializer = ^json
  )

  -- 4. Quarto report
  report = node(script = "src/report.qmd", runtime = Quarto)
}

populate_pipeline(p, build = true, verbose = 1)
pipeline_copy()
