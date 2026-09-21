"""Tests for the severe-day notification gate in scripts/swarms_agent.py.

The pipeline flags individual tokens often; an email should only go out on a
very volatile market-wide day (or a real stablecoin depeg), at most once per
cooldown. Each "sends" test has a sibling that must NOT send.
"""
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

import swarms_agent as sa  # noqa: E402

NOW = datetime(2026, 9, 21, 12, 0, tzinfo=timezone.utc)
CURRENT_TS = pd.Timestamp("2026-09-21 12:00", tz="UTC")
CORE = ["RAY", "BONK", "DRIFT", "WIF", "PYTH", "JUP", "KMNO", "SOL", "HNT", "JTO", "ORCA", "RENDER"]
STABLES = ["USDC", "USDT"]
LST = ["JitoSOL", "mSOL"]


def frame(changes, stable_prices=(0.9997, 0.9995), lst_change=1.0):
    """Analysis-shaped frame. `changes` is a list of 24h % moves for CORE tokens."""
    rows = [
        {"token": t, "price_usd": 1.0, "price_change_24h": c, "is_stablecoin": False,
         "trigger_alert": False, "depeg_alert": False, "source": "jupiter",
         "fetched_at": CURRENT_TS}
        for t, c in zip(CORE, changes)
    ]
    rows += [
        {"token": t, "price_usd": p, "price_change_24h": -0.2, "is_stablecoin": True,
         "trigger_alert": abs(p - 1.0) > 0.005, "depeg_alert": abs(p - 1.0) > 0.005,
         "source": "jupiter", "fetched_at": CURRENT_TS}
        for t, p in zip(STABLES, stable_prices)
    ]
    rows += [
        {"token": t, "price_usd": 150.0, "price_change_24h": lst_change, "is_stablecoin": False,
         "trigger_alert": False, "depeg_alert": False, "source": "jupiter",
         "fetched_at": CURRENT_TS}
        for t in LST
    ]
    return pd.DataFrame(rows)


def calm(n=12, move=2.0):
    return [move] * n


# ---- market_severity ----

def test_calm_market_is_calm():
    status, reasons = sa.market_severity(frame(calm()))
    assert status == sa.CALM and reasons == []


def test_broad_severe_day_is_severe():
    status, reasons = sa.market_severity(frame([15.0] * 12))
    assert status == sa.SEVERE
    assert "median" in reasons[0]


def test_threshold_boundary():
    at = sa.SEVERE_MEDIAN_ABS_CHANGE_PCT
    assert sa.market_severity(frame([at] * 12))[0] == sa.SEVERE
    assert sa.market_severity(frame([at - 0.1] * 12))[0] == sa.CALM


def test_negative_moves_count_by_magnitude():
    assert sa.market_severity(frame([-15.0] * 12))[0] == sa.SEVERE


def test_one_wild_token_is_not_a_severe_day():
    """KMNO +31% on its own was part of the noise that triggered the emails."""
    changes = calm()
    changes[CORE.index("KMNO")] = 31.42
    assert sa.market_severity(frame(changes))[0] == sa.CALM


def test_the_2026_09_21_alert_snapshot_does_not_reach_the_threshold():
    """The alert that prompted this change: broad rally, median ~10%."""
    moves = {"RAY": 5.73, "BONK": 10.11, "DRIFT": 12.69, "WIF": 11.99, "PYTH": 9.94,
             "JUP": 12.33, "KMNO": 31.42, "SOL": 7.34, "HNT": 7.45, "JTO": 2.90,
             "ORCA": 6.48, "RENDER": 15.76}
    status, reasons = sa.market_severity(frame([moves[t] for t in CORE]))
    assert status == sa.CALM, reasons


def test_liquid_staking_tokens_do_not_count_toward_breadth():
    """LSTs track SOL; +30% on them alone must not tip the median."""
    assert sa.market_severity(frame(calm(), lst_change=30.0))[0] == sa.CALM


def test_stablecoin_depeg_below_severe_threshold_is_calm():
    assert sa.market_severity(frame(calm(), stable_prices=(0.99, 1.0)))[0] == sa.CALM


def test_stablecoin_depeg_at_or_above_threshold_is_severe_in_a_calm_market():
    status, reasons = sa.market_severity(frame(calm(), stable_prices=(0.975, 1.0)))
    assert status == sa.SEVERE
    assert "USDC" in reasons[0] and "depeg" in reasons[0]


def test_too_few_core_tokens_is_indeterminate_not_calm():
    df = frame(calm())
    df = df[~df.token.isin(CORE[: len(CORE) - (sa.MIN_CORE_TOKENS - 1)])]
    status, reasons = sa.market_severity(df)
    assert status == sa.INDETERMINATE
    assert "core tokens" in reasons[0]


def test_missing_24h_changes_are_indeterminate():
    df = frame(calm())
    df["price_change_24h"] = None
    assert sa.market_severity(df)[0] == sa.INDETERMINATE


def test_depeg_is_still_determinate_when_breadth_cannot_be_assessed():
    df = frame(calm(), stable_prices=(0.95, 1.0))
    df["price_change_24h"] = None
    assert sa.market_severity(df)[0] == sa.SEVERE


def test_missing_column_is_indeterminate():
    assert sa.market_severity(frame(calm()).drop(columns=["is_stablecoin"]))[0] == sa.INDETERMINATE


# ---- cooldown, derived from the committed price history ----

def history_snapshot(ts, changes):
    """History rows for one snapshot (no is_stablecoin column, like the real file)."""
    df = frame(changes)
    df = df[["token", "price_usd", "price_change_24h"]].copy()
    df["fetched_at"] = pd.Timestamp(ts, tz="UTC")
    return df


def history(*snapshots):
    return pd.concat([history_snapshot(ts, ch) for ts, ch in snapshots], ignore_index=True)


def test_cooldown_no_severe_snapshot_in_window_is_infinite_age():
    h = history(("2026-09-19 12:00", calm()), ("2026-09-20 12:00", calm()))
    age, _ = sa.days_since_last_severe(h, CURRENT_TS, NOW)
    assert age == float("inf")


def test_cooldown_finds_the_newest_earlier_severe_snapshot():
    h = history(("2026-09-18 12:00", [15.0] * 12), ("2026-09-19 12:00", [15.0] * 12),
                ("2026-09-20 12:00", calm()))
    age, _ = sa.days_since_last_severe(h, CURRENT_TS, NOW)
    assert age == pytest.approx(2.0)


def test_cooldown_ignores_the_current_snapshot():
    """The current run's own rows are already in the history file."""
    h = history(("2026-09-21 12:00", [15.0] * 12))
    assert sa.days_since_last_severe(h, CURRENT_TS, NOW)[0] == float("inf")


def test_cooldown_ignores_severe_snapshots_older_than_the_window():
    h = history(("2026-09-01 12:00", [15.0] * 12), ("2026-09-20 12:00", calm()))
    assert sa.days_since_last_severe(h, CURRENT_TS, NOW)[0] == float("inf")


def test_cooldown_unreadable_history_is_indeterminate_not_no_alert():
    age, why = sa.days_since_last_severe(None, CURRENT_TS, NOW)
    assert age is None and "not readable" in why


def test_cooldown_history_missing_columns_is_indeterminate():
    h = history(("2026-09-20 12:00", calm())).drop(columns=["price_change_24h"])
    age, why = sa.days_since_last_severe(h, CURRENT_TS, NOW)
    assert age is None and "price_change_24h" in why


def test_load_history_reports_a_missing_file(tmp_path):
    df, why = sa.load_history(tmp_path / "nope.parquet")
    assert df is None and "Error" in why


# ---- labels ----

def test_volatile_token_is_not_labelled_a_depeg():
    """Regression: every triggered token used to be reported as 'depegged'."""
    df = frame(calm())
    df.loc[df.token == "DRIFT", "trigger_alert"] = True
    prices = df[["token", "price_usd", "price_change_24h", "source"]]
    ctx = sa.build_agent_context(prices, df, "ALERT")
    assert ctx["tokens_flagged"] == ["DRIFT"]
    assert ctx["stablecoins_triggered"] == []


def test_real_depeg_is_listed_as_a_stablecoin_depeg():
    df = frame(calm(), stable_prices=(0.97, 1.0))
    prices = df[["token", "price_usd", "price_change_24h", "source"]]
    ctx = sa.build_agent_context(prices, df, "ALERT")
    assert [s["token"] for s in ctx["stablecoins_triggered"]] == ["USDC"]


def test_subject_carries_the_reason():
    ctx = {"severity_reasons": ["market median |24h change| 13.0% across 12 tokens"]}
    assert "SEVERE" in sa.format_subject(ctx) and "13.0%" in sa.format_subject(ctx)
    assert sa.format_subject({"severity_reasons": []}) == "[crypto_swarms] No alerts"


# ---- main(): what actually gets sent ----

@pytest.fixture
def dispatch(monkeypatch):
    """Run main() against a frame; return the list of transports that fired."""
    def run(df, cooldown_age=float("inf"), force=False):
        sent = []
        prices = df[["token", "price_usd", "price_change_24h", "source", "fetched_at"]]
        monkeypatch.setattr(sa, "read_arrow", lambda name: prices if name == "prices" else df)
        monkeypatch.setattr(sa, "read_json", lambda name: "ALERT")
        monkeypatch.setattr(sa, "DRY_RUN", False)
        monkeypatch.setattr(sa, "FORCE_ALERT", force)
        # `cooldown_age` stands in for days_since_last_severe's answer;
        # None means it could not be determined.
        monkeypatch.setattr(sa, "load_history", lambda *a, **k: (df, None))
        monkeypatch.setattr(sa, "days_since_last_severe",
                            lambda history, current_ts, now: (cooldown_age, "test"))
        monkeypatch.setattr(sa, "send_email_alert", lambda *a, **k: sent.append("email") or True)
        monkeypatch.setattr(sa, "create_github_issue", lambda *a, **k: sent.append("issue") or True)
        sa.main()
        return sent
    return run


def flagged(df):
    df = df.copy()
    df["trigger_alert"] = True  # every token individually flagged, as on a noisy day
    return df


def test_noisy_day_with_many_flags_sends_nothing(dispatch):
    assert dispatch(flagged(frame(calm()))) == []


def test_severe_day_sends_email_and_issue(dispatch):
    assert dispatch(frame([15.0] * 12)) == ["email", "issue"]


def test_severe_day_inside_cooldown_sends_nothing(dispatch):
    assert dispatch(frame([15.0] * 12), cooldown_age=1.0) == []


def test_severe_day_after_cooldown_sends(dispatch):
    assert dispatch(frame([15.0] * 12), cooldown_age=sa.ALERT_COOLDOWN_DAYS + 0.1) == ["email", "issue"]


def test_severe_day_with_unknown_cooldown_still_sends(dispatch):
    assert dispatch(frame([15.0] * 12), cooldown_age=None) == ["email", "issue"]


def test_indeterminate_severity_sends_nothing_but_says_so(dispatch, capsys):
    df = frame(calm())
    df["price_change_24h"] = None
    assert dispatch(flagged(df)) == []
    assert "INDETERMINATE" in capsys.readouterr().out


def test_force_alert_bypasses_gate_and_cooldown(dispatch):
    assert dispatch(frame(calm()), cooldown_age=0.0, force=True) == ["email", "issue"]
