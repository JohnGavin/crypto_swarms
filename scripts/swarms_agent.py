#!/usr/bin/env python3
"""Swarms agent post-step: read pipeline alerts and dispatch notifications.

Runs OUTSIDE the T pipeline (after `t run`), because Swarms needs network for
LLM API calls and Nix sandbox blocks network.

Pipeline:
    fetch_prices.py  ->  t run src/pipeline.t  ->  swarms_agent.py
    (network)            (sandboxed)               (network)

Transports (both gated on n_triggered > 0):
  1. Gmail SMTP via GMAIL_USERNAME / GMAIL_APP_PASSWORD env vars
     (same pattern as irishbuoys/R/email_summary.R, but Python smtplib)
  2. GitHub issue via GH REST API (uses GH_TOKEN, no extra deps)

Env vars:
    SWARMS_DRY_RUN        true (default) | false  -- skip all transports if true
    CRYPTO_FORCE_ALERT    true | false (default)  -- force alert for testing
    GMAIL_USERNAME        Gmail address
    GMAIL_APP_PASSWORD    Gmail app password (not your real password)
    GH_TOKEN              GitHub token (auto-set in GHA)
    ANTHROPIC_API_KEY     Phase 2: real Swarms LLM call
    GH_REPO               default: JohnGavin/crypto_swarms

Usage:
    nix develop --command python3 scripts/swarms_agent.py
"""

import json
import os
import smtplib
import ssl
import sys
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path

import httpx
import pandas as pd
import pyarrow as pa
import pyarrow.ipc as ipc


PIPELINE_OUTPUT = Path("pipeline-output")
DRY_RUN = os.environ.get("SWARMS_DRY_RUN", "true").lower() != "false"
FORCE_ALERT = os.environ.get("CRYPTO_FORCE_ALERT", "false").lower() == "true"
GH_REPO = os.environ.get("GH_REPO", "JohnGavin/crypto_swarms")

# ---------- Notification policy: only a very volatile day gets through ----------
# The pipeline's per-token triggers (robust z, Bollinger, liquidity, regime)
# still run and still populate the report; they no longer send email by
# themselves. A notification needs a market-wide severe day, or a real
# stablecoin depeg, and then respects a cooldown.
#
# Calibration (2026-09-21, data/price_history.parquet, 284 snapshots since
# 2026-04-12): the median absolute 24h move of the 12 core tokens peaked at
# 9.72% in 5 months (>=8% on 8 snapshots), and the 2026-09-21 12:16 UTC alert
# read about 10.0%. 12% sits above everything recorded; roughly 1-2 a year is
# the target, but 5 months cannot confirm that rate. Override to tune.
SEVERE_MEDIAN_ABS_CHANGE_PCT = float(os.environ.get("CRYPTO_SEVERE_MEDIAN_PCT", "12"))
# Stablecoin depeg that counts as severe (the per-token trigger stays at 0.5%).
SEVERE_DEPEG = float(os.environ.get("CRYPTO_SEVERE_DEPEG", "0.02"))
# At most one notification per this many days: no email if any earlier
# snapshot inside this window was already severe (see days_since_last_severe).
ALERT_COOLDOWN_DAYS = float(os.environ.get("CRYPTO_ALERT_COOLDOWN_DAYS", "7"))
HISTORY_PATH = Path("data/price_history.parquet")
# Mirrors STABLECOINS in R/analysis_functions.R; history rows have no
# is_stablecoin column, so the token name is the only signal available there.
STABLECOIN_TOKENS = {"USDC", "USDT"}
# Breadth needs enough tokens to be a median of a market, not of a handful.
MIN_CORE_TOKENS = 8
# SOL liquid-staking tokens track SOL, so counting them would weight SOL 3x.
LIQUID_STAKING_TOKENS = {"JitoSOL", "mSOL"}

SEVERE, CALM, INDETERMINATE = "SEVERE", "CALM", "INDETERMINATE"


# ---------- Pipeline I/O ----------

def read_arrow(name):
    path = PIPELINE_OUTPUT / name / "artifact"
    if not path.exists():
        raise FileNotFoundError(
            "Missing {}. Run `t run src/pipeline.t` first.".format(path)
        )
    with pa.OSFile(str(path), "rb") as f:
        return ipc.open_file(f).read_pandas()


def read_json(name):
    path = PIPELINE_OUTPUT / name / "artifact"
    if not path.exists():
        raise FileNotFoundError(
            "Missing {}. Run `t run src/pipeline.t` first.".format(path)
        )
    return json.loads(path.read_text())


def build_agent_context(prices, analysis, alerts):
    triggered = analysis[analysis["trigger_alert"] == True]
    is_stable = analysis["is_stablecoin"] == True if "is_stablecoin" in analysis else False
    depegged = analysis[is_stable & (analysis["depeg_alert"] == True)] \
        if "depeg_alert" in analysis else analysis.iloc[0:0]
    return {
        "alert_message": alerts,
        "n_triggered": int(len(triggered)),
        "tokens": prices[["token", "price_usd", "price_change_24h"]].to_dict("records"),
        "tokens_flagged": list(triggered["token"]),
        # Only real stablecoin depegs. This used to hold every triggered token,
        # which is why volatile tokens were reported as "depegged".
        "stablecoins_triggered": depegged[["token", "price_usd"]].to_dict("records"),
        "severity": None,
        "severity_reasons": [],
        "data_source": prices["source"].iloc[0] if len(prices) > 0 else "unknown",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    }


# ---------- Severity gate and cooldown ----------

def market_severity(analysis):
    """Is this a very volatile day? Returns (status, reasons).

    SEVERE: a stablecoin depeg >= SEVERE_DEPEG, or the median absolute 24h move
    of the core tokens >= SEVERE_MEDIAN_ABS_CHANGE_PCT.
    CALM: assessed and neither holds.
    INDETERMINATE: could not assess (missing columns, or too few core tokens
    with a 24h change). A depeg finding is still determinate without breadth.
    """
    needed = {"token", "price_usd", "price_change_24h", "is_stablecoin"}
    missing = sorted(needed - set(analysis.columns))
    if missing:
        return INDETERMINATE, ["analysis is missing columns: " + ", ".join(missing)]

    reasons = []
    stable = analysis[analysis["is_stablecoin"] == True]
    for _, row in stable.iterrows():
        deviation = abs(row["price_usd"] - 1.0)
        if deviation >= SEVERE_DEPEG:
            reasons.append("{} depeg {:.2%} from $1".format(row["token"], deviation))

    core = analysis[
        (analysis["is_stablecoin"] != True)
        & ~analysis["token"].isin(LIQUID_STAKING_TOKENS)
    ].dropna(subset=["price_change_24h"])
    if len(core) < MIN_CORE_TOKENS:
        if reasons:
            return SEVERE, reasons
        return INDETERMINATE, [
            "only {} core tokens have a 24h change (need {})".format(len(core), MIN_CORE_TOKENS)
        ]

    median_move = float(core["price_change_24h"].abs().median())
    if median_move >= SEVERE_MEDIAN_ABS_CHANGE_PCT:
        reasons.append(
            "market median |24h change| {:.1f}% across {} tokens (threshold {:.1f}%)".format(
                median_move, len(core), SEVERE_MEDIAN_ABS_CHANGE_PCT
            )
        )
    return (SEVERE if reasons else CALM), reasons


def load_history(path=HISTORY_PATH):
    """Read the committed price history. Returns (DataFrame, None) or (None, reason)."""
    try:
        return pd.read_parquet(path), None
    except Exception as e:  # unreadable history is indeterminate, never "no earlier alert"
        return None, "{}: {}".format(type(e).__name__, e)


def days_since_last_severe(history, current_ts, now):
    """Age in days of the newest EARLIER snapshot that was severe. (days, reason).

    The cooldown is derived from the committed price history rather than from
    stored alert state: the history is present on every run, needs no extra
    permissions, and an email is sent only on the first severe snapshot after
    ALERT_COOLDOWN_DAYS without one. (An earlier design read the newest `alert`
    GitHub issue, but issue creation has failed with 403 since April because the
    workflow lacks `issues: write`, so it would never have suppressed anything.)

    days=None: could not be determined (reason says why), not "no earlier alert".
    days=inf: determinate, no severe snapshot inside the cooldown window.
    """
    needed = {"token", "price_usd", "price_change_24h", "fetched_at"}
    if history is None:
        return None, "price history not readable"
    missing = sorted(needed - set(history.columns))
    if missing:
        return None, "price history is missing columns: " + ", ".join(missing)

    cutoff = pd.Timestamp(now) - pd.Timedelta(days=ALERT_COOLDOWN_DAYS)
    window = history[(history["fetched_at"] < current_ts) & (history["fetched_at"] >= cutoff)].copy()
    window["is_stablecoin"] = window["token"].isin(STABLECOIN_TOKENS)
    newest_severe = None
    for ts, snap in window.groupby("fetched_at"):
        if market_severity(snap)[0] == SEVERE:
            newest_severe = ts if newest_severe is None else max(newest_severe, ts)
    if newest_severe is None:
        return float("inf"), "no severe snapshot in the last {:.0f} days".format(ALERT_COOLDOWN_DAYS)
    return (pd.Timestamp(now) - newest_severe).total_seconds() / 86400.0, \
        "newest earlier severe snapshot {}".format(newest_severe.isoformat())


# ---------- Alert formatters ----------

def format_subject(context):
    reasons = context["severity_reasons"]
    if not reasons:
        return "[crypto_swarms] No alerts"
    return "[crypto_swarms] SEVERE: " + "; ".join(reasons)


def format_body_text(context):
    lines = [
        "Crypto Swarms Alert",
        "=" * 30,
        "",
        "Time: " + context["timestamp_utc"],
        "Source: " + context["data_source"],
        "Why this was sent:",
    ]
    lines.extend("  - " + r for r in context["severity_reasons"])
    lines.extend([
        "",
        "Per-token flags ({}): {}".format(
            context["n_triggered"], ", ".join(context["tokens_flagged"]) or "none"
        ),
        "",
        "Tokens:",
    ])
    for tok in context["tokens"]:
        change = tok.get("price_change_24h")
        change_str = " ({:+.2f}%)".format(change) if change is not None else ""
        lines.append("  {:<6} ${:>12.6f}{}".format(
            tok["token"], tok["price_usd"], change_str
        ))
    if context["stablecoins_triggered"]:
        lines.extend(["", "DEPEGGED:"])
        for s in context["stablecoins_triggered"]:
            lines.append("  {} at ${:.6f}".format(s["token"], s["price_usd"]))
    return "\n".join(lines)


def format_body_html(context):
    rows = "".join(
        "<tr><td>{}</td><td>${:.6f}</td><td>{}</td></tr>".format(
            t["token"],
            t["price_usd"],
            "{:+.2f}%".format(t["price_change_24h"]) if t.get("price_change_24h") is not None else "",
        )
        for t in context["tokens"]
    )
    callout = (
        '<div style="background:#fff3cd;border:1px solid #ffeeba;padding:10px;'
        'border-radius:4px;"><strong>SEVERE:</strong> {}</div>'.format(
            "; ".join(context["severity_reasons"])
        )
        if context["severity_reasons"]
        else '<div style="color:#666;">No alerts triggered.</div>'
    )
    return """<html><body style="font-family:sans-serif;">
<h2>Crypto Swarms Alert</h2>
{callout}
<p><strong>Time:</strong> {time}<br>
<strong>Source:</strong> {source}</p>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;">
<tr><th>Token</th><th>Price (USD)</th><th>24h Change</th></tr>
{rows}
</table>
</body></html>""".format(
        callout=callout,
        time=context["timestamp_utc"],
        source=context["data_source"],
        rows=rows,
    )


# ---------- Transport: Gmail SMTP ----------

def send_email_alert(subject, body_text, body_html):
    """Send via Gmail SMTP. Mirrors irishbuoys/R/email_summary.R pattern."""
    user = os.environ.get("GMAIL_USERNAME")
    pwd = os.environ.get("GMAIL_APP_PASSWORD")
    if not (user and pwd):
        print("[email] SKIPPED: GMAIL_USERNAME / GMAIL_APP_PASSWORD not set")
        return False

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = user
    msg["To"] = user  # send to self by default
    msg.set_content(body_text)
    msg.add_alternative(body_html, subtype="html")

    try:
        with smtplib.SMTP_SSL(
            "smtp.gmail.com", 465, context=ssl.create_default_context()
        ) as s:
            s.login(user, pwd)
            s.send_message(msg)
        print("[email] Sent to {}".format(user))
        return True
    except Exception as e:
        print("[email] FAILED: {}".format(e), file=sys.stderr)
        return False


# ---------- Transport: GitHub issue ----------

def create_github_issue(title, body):
    """Create a GH issue via REST API. Uses GH_TOKEN env var (auto-set in GHA)."""
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        print("[gh] SKIPPED: GH_TOKEN / GITHUB_TOKEN not set")
        return False

    url = "https://api.github.com/repos/{}/issues".format(GH_REPO)
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    payload = {"title": title, "body": body, "labels": ["alert", "automated"]}

    try:
        resp = httpx.post(url, headers=headers, json=payload, timeout=30)
        resp.raise_for_status()
        issue_url = resp.json().get("html_url", "(unknown)")
        print("[gh] Created issue: {}".format(issue_url))
        return True
    except Exception as e:
        print("[gh] FAILED: {}".format(e), file=sys.stderr)
        return False


# ---------- LLM backend: Claude Code CLI (Max subscription) ----------

def _find_claude_binary():
    """Find the OAuth-authenticated claude binary.

    Prefers the env var CLAUDE_BIN, then Homebrew (where `claude /login` stores
    credentials for interactive Max subscription users), then PATH. Inside
    `nix develop` shells, the Nix-bundled claude has no OAuth creds and exits
    silently — avoid it.
    """
    from shutil import which
    explicit = os.environ.get("CLAUDE_BIN")
    if explicit and os.path.exists(explicit):
        return explicit
    for candidate in ("/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if os.path.exists(candidate):
            return candidate
    return which("claude") or "claude"


def call_claude_cli(context, timeout=120):
    """Invoke `claude -p` to analyse the alert context.

    Uses the local Claude Code CLI with the user's Max subscription (OAuth).
    Explicitly unsets ANTHROPIC_API_KEY so -p doesn't fall back to API credits.
    Uses absolute path to Homebrew's claude to avoid Nix-shell shadowing.

    Returns the LLM response as a string, or an error message.
    """
    import subprocess

    prompt = (
        "You are a crypto alert analyst. Given this pipeline output, decide "
        "whether the alert is a real depeg, a data glitch, or a noise event. "
        "Respond in <=3 short bullet points with: (1) verdict, (2) confidence "
        "(low/med/high), (3) recommended action.\n\n"
        "Context:\n" + json.dumps(context, indent=2, default=str)
    )

    claude_bin = _find_claude_binary()

    # Remove ANTHROPIC_API_KEY from env so claude -p uses subscription OAuth
    env = os.environ.copy()
    env.pop("ANTHROPIC_API_KEY", None)

    try:
        result = subprocess.run(
            [claude_bin, "-p"],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        if result.returncode != 0:
            return (
                "[claude -p] exit {} (binary: {})\n"
                "  stdout: {}\n"
                "  stderr: {}"
            ).format(
                result.returncode,
                claude_bin,
                result.stdout.strip()[:500] or "(empty)",
                result.stderr.strip()[:500] or "(empty)",
            )
        return result.stdout.strip()
    except FileNotFoundError:
        return "[claude -p] claude CLI not found — install Claude Code"
    except subprocess.TimeoutExpired:
        return "[claude -p] timed out after {}s".format(timeout)
    except Exception as e:
        return "[claude -p] error: {}".format(e)


# ---------- Main ----------

def main():
    print("=" * 50)
    print("Swarms Agent Post-Step")
    print("=" * 50)

    prices = read_arrow("prices")
    analysis = read_arrow("analysis")
    alerts = read_json("alerts")

    print("\nLoaded pipeline outputs:")
    print("  prices:   {} rows".format(len(prices)))
    print("  analysis: {} rows ({} triggered)".format(
        len(analysis), int(analysis["trigger_alert"].sum())
    ))
    print("  alerts:   {}".format(alerts))

    context = build_agent_context(prices, analysis, alerts)

    status, reasons = market_severity(analysis)
    context["severity"] = status
    context["severity_reasons"] = reasons
    print("\nSeverity: {} {}".format(status, reasons))

    if FORCE_ALERT:
        print("\n[FORCE_ALERT=true] Synthesizing test alert (gate and cooldown bypassed)")
        context["severity"] = SEVERE
        context["severity_reasons"] = ["TEST ALERT: synthetic, for transport testing"]
    elif status != SEVERE:
        # CALM and INDETERMINATE both send nothing, but they are reported
        # differently: INDETERMINATE means the gate could not be evaluated.
        print("\nNo notification: per-token flags={} but market severity is {}.".format(
            context["n_triggered"], status
        ))
        return
    else:
        history, history_err = load_history()
        if history is None:
            age, why = None, history_err
        else:
            age, why = days_since_last_severe(
                history, prices["fetched_at"].max(), datetime.now(timezone.utc)
            )
        if age is None:
            print("\n[cooldown] INDETERMINATE ({}): not suppressing a severe alert.".format(why))
        elif age < ALERT_COOLDOWN_DAYS:
            print("\nNo notification: severe, but the last alert was {:.1f} days ago "
                  "(cooldown {:.0f} days; {}).".format(age, ALERT_COOLDOWN_DAYS, why))
            return

    print("\nAgent context:")
    print(json.dumps(context, indent=2, default=str))

    # Build alert artifacts
    subject = format_subject(context)
    body_text = format_body_text(context)
    body_html = format_body_html(context)

    # LLM analysis via Claude Code CLI — runs even in dry-run (read-only)
    llm_verdict = None
    if os.environ.get("CRYPTO_LLM_ANALYSIS", "false").lower() == "true":
        print("\nInvoking `claude -p` for analysis...")
        llm_verdict = call_claude_cli(context)
        print(llm_verdict)

    if DRY_RUN:
        print("\n[DRY RUN] Would send the following:")
        print("\nSubject: " + subject)
        print("\n--- Body (text) ---")
        print(body_text)
        print("\nSet SWARMS_DRY_RUN=false to actually dispatch transports.")
        return

    # Append LLM verdict to body if we got one
    if llm_verdict:
        body_text += "\n\n--- LLM Analysis ---\n" + llm_verdict
        body_html += "<hr><h3>LLM Analysis</h3><pre>{}</pre>".format(llm_verdict)

    # Live dispatch
    print("\nDispatching transports...")
    sent_email = send_email_alert(subject, body_text, body_html)
    sent_issue = create_github_issue(subject, "```\n" + body_text + "\n```")
    print("\nResult: email={}, gh_issue={}".format(sent_email, sent_issue))


if __name__ == "__main__":
    main()
