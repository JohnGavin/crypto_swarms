"""Tests for scripts/historical_contract.py (issue #19 data contract).

Every test that expects a clean result has a sibling that feeds the same check
a broken input and asserts it is NOT clean.
"""
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

import historical_contract as hc  # noqa: E402

NOW = datetime(2026, 9, 21, tzinfo=timezone.utc)
MACRO_KEYS = hc.CONTRACT["macro_daily"]["required_keys"]
CRYPTO_KEYS = hc.CONTRACT["crypto_daily"]["required_keys"]


def macro_frame(keys=MACRO_KEYS, last="2026-09-18"):
    rows = [
        {"date": pd.Timestamp(d).date(), "value": 1.0, "series_id": k, "source": "FRED"}
        for k in keys for d in ("2026-09-10", last)
    ]
    return pd.DataFrame(rows)


def crypto_frame(keys=CRYPTO_KEYS, last="2026-09-20"):
    rows = [
        {"date": pd.Timestamp(d), "close": 1.0, "volume": 5.0, "ticker": k, "source": "yahoo"}
        for k in keys for d in ("2026-09-10", last)
    ]
    return pd.DataFrame(rows)


# ---- validate(): the three ways a dataset can violate the contract ----

def test_clean_macro_passes():
    r = hc.validate("macro_daily", macro_frame(), NOW)
    assert r.status == hc.PASS, r.findings


def test_clean_crypto_passes():
    r = hc.validate("crypto_daily", crypto_frame(), NOW)
    assert r.status == hc.PASS, r.findings


def test_missing_required_column_fails():
    """Dataset missing a required column must FAIL, naming the column."""
    r = hc.validate("crypto_daily", crypto_frame().drop(columns=["volume"]), NOW)
    assert r.status == hc.FAIL
    assert "volume" in r.findings[0]


def test_missing_required_series_fails():
    r = hc.validate("macro_daily", macro_frame(keys=MACRO_KEYS[:-1]), NOW)
    assert r.status == hc.FAIL
    assert MACRO_KEYS[-1] in " ".join(r.findings)


def test_stale_series_fails():
    """The real published crypto_daily ended 2026-04-12: it must FAIL on age."""
    r = hc.validate("crypto_daily", crypto_frame(last="2026-04-12"), NOW)
    assert r.status == hc.FAIL
    assert "stale" in " ".join(r.findings)


def test_all_null_values_do_not_count_as_fresh():
    """A series whose newest rows are null is stale, judged on non-null values."""
    df = macro_frame()
    df.loc[df["series_id"] == "DGS10", "value"] = None
    r = hc.validate("macro_daily", df, NOW)
    assert r.status == hc.FAIL
    assert "DGS10" in " ".join(r.findings)


def test_empty_dataset_fails():
    r = hc.validate("macro_daily", macro_frame().iloc[0:0], NOW)
    assert r.status == hc.FAIL


def test_timestamp_and_date_keys_join_after_coercion():
    """crypto date is TIMESTAMP, macro date is DATE.

    pandas refuses the raw merge outright; dplyr::full_join(by = "date") on the
    same types silently matches nothing, so coerce at the boundary either way.
    """
    crypto, macro = crypto_frame(), macro_frame()
    with pytest.raises(ValueError):
        crypto.merge(macro, on="date")
    crypto["date"] = hc.coerce_date(crypto["date"])
    macro["date"] = hc.coerce_date(macro["date"])
    assert len(crypto.merge(macro, on="date")) > 0


# ---- check_dataset(): unreadable is not the same as clean ----

def test_http_error_is_indeterminate_not_pass():
    def fetcher(dataset, base_url):
        return None, "https://example.invalid/x.parquet returned HTTP 503"
    r = hc.check_dataset("macro_daily", "https://example.invalid", NOW, fetcher)
    assert r.status == hc.INDETERMINATE
    assert "503" in r.findings[0]


def test_unreadable_parquet_is_fail():
    """Reachable but corrupt content is an observed violation, not an unknown."""
    def fetcher(dataset, base_url):
        return None, "PARSE:ArrowInvalid: not a parquet file"
    r = hc.check_dataset("macro_daily", "https://example.invalid", NOW, fetcher)
    assert r.status == hc.FAIL


def test_fail_outranks_indeterminate():
    def fetcher(dataset, base_url):
        if dataset == "macro_daily":
            return None, "network down"
        return crypto_frame(last="2026-04-12"), None
    status, results = hc.run(["macro_daily", "crypto_daily"], "x", NOW, fetcher)
    assert status == hc.FAIL
    assert {r.status for r in results} == {hc.FAIL, hc.INDETERMINATE}


def test_summary_line_reports_indeterminate_count():
    results = [hc.Result("a", hc.PASS), hc.Result("b", hc.INDETERMINATE)]
    assert "indeterminate=1" in hc.summary_line(results)


# ---- CLI: a genuinely unreachable host must exit 3 and never print PASS ----

def test_cli_unreachable_exits_3_and_never_reports_pass(capsys):
    """Real connection refused (nothing listens on port 1), not a stub."""
    rc = hc.main(["--dataset", "macro_daily", "--base-url", "http://127.0.0.1:1"])
    out = capsys.readouterr().out
    assert rc == 3, out
    assert "INDETERMINATE" in out
    assert "PASS" not in out


def test_cli_usage_error_exits_2():
    with pytest.raises(SystemExit) as e:
        hc.main(["--dataset", "no_such_dataset"])
    assert e.value.code == 2
