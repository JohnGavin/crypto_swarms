#!/usr/bin/env python3
"""Swarms agent post-step: read pipeline alerts and act on them.

Runs OUTSIDE the T pipeline (after `t run`), because Swarms needs network for
LLM API calls and Nix sandbox blocks network.

Architecture:
    fetch_prices.py  ->  t run src/pipeline.t  ->  swarms_agent.py
    (network)            (sandboxed)               (network)

Phase 1 (this file): stub that reads alerts/prices and prints what it WOULD do.
Phase 2 (future): wire up real Swarms agent with LLM-driven decisions.

Usage:
    nix develop --command python3 scripts/swarms_agent.py
    # Optional env vars for Phase 2:
    #   SWARMS_DRY_RUN=false  ANTHROPIC_API_KEY=sk-...

Set SWARMS_DRY_RUN=false to actually invoke an LLM (requires API key).
"""

import json
import os
import sys
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.ipc as ipc


PIPELINE_OUTPUT = Path("pipeline-output")
DRY_RUN = os.environ.get("SWARMS_DRY_RUN", "true").lower() != "false"


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
    """Construct the context dict that would be sent to a Swarms agent."""
    triggered = analysis[analysis["trigger_alert"] == True]
    return {
        "alert_message": alerts,
        "n_triggered": int(len(triggered)),
        "tokens": prices[["token", "price_usd", "price_change_24h"]].to_dict("records"),
        "stablecoins": triggered[["token", "price_usd"]].to_dict("records") if len(triggered) > 0 else [],
        "data_source": prices["source"].iloc[0] if len(prices) > 0 else "unknown",
    }


def call_swarms_agent(context):
    """Phase 2: invoke a Swarms agent with the context.

    Wired up here to fail loudly if called without the SDK installed.
    For Phase 1 we never reach this — DRY_RUN is True.
    """
    try:
        from swarms import Agent  # noqa: F401
    except ImportError:
        print("ERROR: swarms package not installed. Add to flake.nix py-env.", file=sys.stderr)
        sys.exit(1)

    # Phase 2 starter — uncomment when ready:
    # from swarms.models import OpenAIChat
    # agent = Agent(
    #     agent_name="crypto-alert-responder",
    #     system_prompt="You are a crypto alert bot. Given price data and alerts, "
    #                   "decide whether to send a notification, log to a file, "
    #                   "or take no action. Be conservative.",
    #     llm=OpenAIChat(model_name="gpt-4o-mini"),
    #     max_loops=1,
    # )
    # response = agent.run(json.dumps(context))
    # return response
    return "Phase 2 stub: Swarms SDK not yet wired up"


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

    print("\nAgent context:")
    print(json.dumps(context, indent=2, default=str))

    if DRY_RUN:
        print("\n[DRY RUN] Would invoke Swarms agent with context above.")
        print("Set SWARMS_DRY_RUN=false to actually call the agent.")
    else:
        print("\nInvoking Swarms agent...")
        response = call_swarms_agent(context)
        print("Agent response:")
        print(response)


if __name__ == "__main__":
    main()
