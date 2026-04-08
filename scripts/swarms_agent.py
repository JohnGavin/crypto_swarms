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
    return {
        "alert_message": alerts,
        "n_triggered": int(len(triggered)),
        "tokens": prices[["token", "price_usd", "price_change_24h"]].to_dict("records"),
        "stablecoins_triggered": (
            triggered[["token", "price_usd"]].to_dict("records")
            if len(triggered) > 0 else []
        ),
        "data_source": prices["source"].iloc[0] if len(prices) > 0 else "unknown",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    }


# ---------- Alert formatters ----------

def format_subject(context):
    n = context["n_triggered"]
    if n == 0:
        return "[crypto_swarms] No alerts"
    tickers = ",".join(s["token"] for s in context["stablecoins_triggered"])
    return "[crypto_swarms] ALERT: {} depeg ({})".format(tickers, n)


def format_body_text(context):
    lines = [
        "Crypto Swarms Alert",
        "=" * 30,
        "",
        "Time: " + context["timestamp_utc"],
        "Source: " + context["data_source"],
        "Alert: " + context["alert_message"],
        "",
        "Triggered: " + str(context["n_triggered"]),
        "",
        "Tokens:",
    ]
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
        'border-radius:4px;"><strong>ALERT:</strong> {}</div>'.format(context["alert_message"])
        if context["n_triggered"] > 0
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

def call_claude_cli(context, timeout=120):
    """Invoke `claude -p` to analyse the alert context.

    Uses the local Claude Code CLI with the user's Max subscription (OAuth).
    Explicitly unsets ANTHROPIC_API_KEY so -p doesn't fall back to API credits.

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

    # Remove ANTHROPIC_API_KEY from env so claude -p uses subscription OAuth
    env = os.environ.copy()
    env.pop("ANTHROPIC_API_KEY", None)

    try:
        result = subprocess.run(
            ["claude", "-p"],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        if result.returncode != 0:
            return "[claude -p] exit {}: {}".format(result.returncode, result.stderr.strip())
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

    if FORCE_ALERT and context["n_triggered"] == 0:
        print("\n[FORCE_ALERT=true] Synthesizing test alert")
        context["n_triggered"] = 1
        context["stablecoins_triggered"] = [{"token": "TEST", "price_usd": 0.95}]
        context["alert_message"] = "TEST ALERT — synthetic depeg for transport testing"

    print("\nAgent context:")
    print(json.dumps(context, indent=2, default=str))

    if context["n_triggered"] == 0:
        print("\nNo action needed (no triggered alerts).")
        return

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
