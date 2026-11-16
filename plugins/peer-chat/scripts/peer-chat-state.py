#!/usr/bin/env python3
"""Inspect a topic and record timer actions without driving either agent."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import now_utc, repo_root, stamp
from peer_chat_state import (
    StateError, Store, begin, due, finish, next_wake, nudge_submitted, observe, release, status, withdraw,
)


def state_path(slug: str, explicit: str | None = None) -> Path:
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", slug):
        raise StateError("slug must be a single topic name")
    path = Path(explicit).expanduser().resolve() if explicit else repo_root() / "tmp/peer-chat" / slug / "state.json"
    if path.name != "state.json":
        raise StateError("--state must name a topic's state.json")
    return path


def parse_token(value: str) -> dict:
    try:
        token = json.loads(value)
    except json.JSONDecodeError as error:
        raise argparse.ArgumentTypeError("token must be a JSON object from wake") from error
    if not isinstance(token, dict):
        raise argparse.ArgumentTypeError("token must be a JSON object from wake")
    return token


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    cli.add_argument("--slug", required=True)
    cli.add_argument("--state")
    commands = cli.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("wake")
    for name in ("begin", "finish", "nudged"):
        command = commands.add_parser(name)
        command.add_argument("--token", type=parse_token, required=True)
        if name != "nudged":
            command.add_argument("--action", choices=("nudge", "stop"), required=True)
        if name == "finish":
            command.add_argument("--outcome", choices=("ok", "failed"), required=True)
            command.add_argument("--detail", default="")
    command = commands.add_parser("release")
    command.add_argument("--ask-id", required=True)
    command.add_argument("--evidence", type=Path, required=True)
    command = commands.add_parser("observe")
    command.add_argument("--message-id", required=True)
    command.add_argument("--event", choices=("submit_sent", "acknowledged", "answered", "failed", "cancelled", "uncertain"), required=True)
    command.add_argument("--evidence", type=Path, required=True)
    command.add_argument("--actor-id", required=True)
    command = commands.add_parser("withdraw")
    command.add_argument("--ask-id", required=True)
    command.add_argument("--actor-id", required=True)
    command.add_argument("--reason", required=True)
    command.add_argument("--evidence", type=Path, required=True)
    return cli


def wake_status(store: Store) -> dict:
    moment = now_utc()
    timers = [timer for timer in store.read()["timers"].values()
              if timer["phase"] in ("armed", "nudged") and timer["intent"] is None]
    wake_at = next_wake(store, min(timer["budgets"]["wake"]["seconds"] for timer in timers), now=moment) if timers else None
    delay = max(0, (datetime.strptime(wake_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) - moment).total_seconds()) if wake_at else None
    return {"due": due(store, now=moment), "next_wake_at": wake_at,
            "wake_in_seconds": delay, "observed_at": stamp(moment)}


def run(args: argparse.Namespace, store: Store):
    if args.command == "status":
        return status(store)
    if args.command == "wake":
        return wake_status(store)
    if args.command == "begin":
        return begin(store, args.token, args.action)
    if args.command == "finish":
        return finish(store, args.token, args.action, args.outcome, detail=args.detail)
    if args.command == "nudged":
        return {"grace_expires_at": nudge_submitted(store, args.token)}
    if args.command == "release":
        return release(store, args.ask_id, args.evidence)
    if args.command == "withdraw":
        return withdraw(store, args.ask_id, actor=args.actor_id, reason=args.reason, evidence=args.evidence)
    return observe(store, args.message_id, args.event, evidence=args.evidence, actor=args.actor_id)


def main() -> int:
    args = parser().parse_args()
    try:
        store = Store(state_path(args.slug, args.state))
        state = store.read()
        if state.get("slug") != args.slug or state.get("transport") != "agterm":
            raise StateError("state does not belong to this agterm topic")
        print(json.dumps(run(args, store), ensure_ascii=False))
        return 0
    except (StateError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"peer-chat-state: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
