#!/usr/bin/env python3
"""Data contract for the shared `historical` dataset (issue #19).

`historical` is the single source of truth for crypto + macro market data.
This repo consumes the PUBLISHED copy (Hugging Face dataset
JohnGavin/finance-data), never a path into another checkout, and never
re-fetches what `historical` owns.

The contract, per dataset:
  * required columns (a missing column is a FAIL)
  * required keys: macro series ids, crypto tickers (a missing key is a FAIL)
  * maximum staleness of the newest observation (too old is a FAIL)
  * `date` is coerced to a plain calendar date at this boundary: the published
    crypto_daily.date is TIMESTAMP while macro_daily.date is DATE, and a join
    between the two on the raw types silently matches nothing.

Three outcomes, never two (see checks-must-distinguish-unknown):
  PASS           exit 0  every dataset reachable and within contract
  FAIL           exit 1  a dataset was read and violates the contract
  INDETERMINATE  exit 3  a dataset could not be read (network, HTTP status);
                         this is NOT "no alerts" and must not be treated as clean
  (exit 2 = usage error, from argparse)

A FAIL outranks an INDETERMINATE: a violation already observed is a
determinate result even if another dataset could not be checked.

Usage:
    nix develop --command python3 scripts/historical_contract.py
    nix develop --command python3 scripts/historical_contract.py --dataset macro_daily
"""

import argparse
import io
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone

import httpx
import pandas as pd

BASE_URL = "https://huggingface.co/datasets/JohnGavin/finance-data/resolve/main"
FETCH_TIMEOUT_SECONDS = 60

PASS, FAIL, INDETERMINATE = "PASS", "FAIL", "INDETERMINATE"
EXIT_CODES = {PASS: 0, FAIL: 1, INDETERMINATE: 3}

# Staleness bounds (days between now and the newest non-null observation).
# Observed 2026-09-20 in the published macro_daily: daily FRED series lag 1-3
# days; DTWEXBGS (weekly-lagged dollar index) lagged 9 days. 10 days catches a
# stalled feed without flagging the normal weekend/holiday/weekly lag.
MACRO_MAX_STALE_DAYS = 10
# crypto_daily is a daily series, so a week without a new row is a stall.
CRYPTO_MAX_STALE_DAYS = 7

CONTRACT = {
    "macro_daily": {
        "columns": ["date", "value", "series_id", "source"],
        "key_column": "series_id",
        # Named in #19 P3. Daily gold is NOT required yet: it is owned by
        # historical#872 and does not exist in the dataset.
        "required_keys": ["DGS10", "DGS30", "DGS2", "DTWEXBGS", "T10YIE", "VIXCLS"],
        "value_column": "value",
        "max_stale_days": MACRO_MAX_STALE_DAYS,
    },
    "crypto_daily": {
        "columns": ["date", "close", "volume", "ticker", "source"],
        "key_column": "ticker",
        # Minimum this repo needs from the shared copy: SOL price and the two
        # stablecoins its depeg checks watch.
        "required_keys": ["SOL", "USDC", "USDT"],
        "value_column": "close",
        "max_stale_days": CRYPTO_MAX_STALE_DAYS,
    },
}


@dataclass
class Result:
    dataset: str
    status: str
    findings: list = field(default_factory=list)


def coerce_date(series):
    """Coerce a TIMESTAMP or DATE column to a plain calendar date."""
    return pd.to_datetime(series).dt.normalize()


def validate(dataset, df, now):
    """Check a loaded frame against its contract. Returns a Result (PASS/FAIL)."""
    spec = CONTRACT[dataset]
    findings = []

    missing = [c for c in spec["columns"] if c not in df.columns]
    if missing:
        # Without the columns the remaining checks cannot be evaluated, but the
        # missing columns are themselves a determinate violation.
        return Result(dataset, FAIL, ["missing columns: " + ", ".join(missing)])
    if df.empty:
        return Result(dataset, FAIL, ["dataset has zero rows"])

    df = df.assign(date=coerce_date(df["date"]))
    key, value = spec["key_column"], spec["value_column"]
    observed = df.dropna(subset=[value])

    absent = [k for k in spec["required_keys"] if k not in set(df[key])]
    if absent:
        findings.append("missing {}: {}".format(key, ", ".join(absent)))

    for k in spec["required_keys"]:
        if k in absent:
            continue
        rows = observed[observed[key] == k]
        if rows.empty:
            findings.append("{} {} has no non-null {}".format(key, k, value))
            continue
        age_days = (now.date() - rows["date"].max().date()).days
        if age_days > spec["max_stale_days"]:
            findings.append(
                "{} {} is stale: newest {} is {} days old (max {})".format(
                    key, k, value, age_days, spec["max_stale_days"]
                )
            )

    return Result(dataset, FAIL if findings else PASS, findings)


def fetch_dataset(dataset, base_url):
    """Download a published parquet. Returns (DataFrame, None) or (None, reason).

    Any failure to READ the dataset is indeterminate: the reason is returned,
    never swallowed into an empty result.
    """
    url = "{}/{}.parquet".format(base_url, dataset)
    try:
        resp = httpx.get(url, timeout=FETCH_TIMEOUT_SECONDS, follow_redirects=True)
    except httpx.HTTPError as e:
        return None, "{} could not be fetched: {}: {}".format(url, type(e).__name__, e)
    if resp.status_code != 200:
        return None, "{} returned HTTP {}".format(url, resp.status_code)
    try:
        return pd.read_parquet(io.BytesIO(resp.content)), None
    except Exception as e:  # noqa: BLE001 - reachable but unreadable is a FAIL below
        return None, "PARSE:{}: {}".format(type(e).__name__, e)


def check_dataset(dataset, base_url, now, fetcher=fetch_dataset):
    df, reason = fetcher(dataset, base_url)
    if reason is not None and reason.startswith("PARSE:"):
        # Reachable (HTTP 200) but not a readable parquet: the observed content
        # violates the contract, so this is a determinate FAIL.
        return Result(dataset, FAIL, ["unreadable parquet: " + reason[len("PARSE:"):]])
    if reason is not None:
        return Result(dataset, INDETERMINATE, [reason])
    return validate(dataset, df, now)


def overall(results):
    statuses = {r.status for r in results}
    if FAIL in statuses:
        return FAIL
    if INDETERMINATE in statuses:
        return INDETERMINATE
    return PASS


def summary_line(results):
    counts = {s: sum(r.status == s for r in results) for s in (PASS, FAIL, INDETERMINATE)}
    return "datasets={} pass={} fail={} indeterminate={}".format(
        len(results), counts[PASS], counts[FAIL], counts[INDETERMINATE]
    )


def run(datasets, base_url, now, fetcher=fetch_dataset):
    results = [check_dataset(d, base_url, now, fetcher) for d in datasets]
    return overall(results), results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--dataset", choices=sorted(CONTRACT), action="append",
                        help="dataset to check (repeatable); default: all")
    parser.add_argument("--base-url", default=BASE_URL,
                        help="where the published parquet files live")
    args = parser.parse_args(argv)

    datasets = args.dataset or sorted(CONTRACT)
    status, results = run(datasets, args.base_url, datetime.now(timezone.utc))

    for r in results:
        print("{:13} {}".format(r.status, r.dataset))
        for f in r.findings:
            print("              - {}".format(f))
    print(summary_line(results))
    print("RESULT: {}".format(status))
    return EXIT_CODES[status]


if __name__ == "__main__":
    sys.exit(main())
