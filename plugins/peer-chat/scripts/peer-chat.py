#!/usr/bin/env python3
"""peer-chat: send one message to the peer agent in the other pane of this agterm split.

The pane transport is umputun's engine, vendored verbatim beside this file: `vendor/peer-chat.py`
inside the plugin, `peer-chat-engine.py` once the installer has copied both onto PATH. The engine
pairs Claude with the left pane and Codex with the right; this adapter drops that pairing. A
participant is a pane slot of the session, the peer is the other slot, and the recipient's
composer protocol follows the harness its pane runs, so claude+claude, codex+codex and mixed
pairs all work in both directions.

    peer-chat.py --to peer --stdin <<'CHAT'
    peer-chat.py --prepare-message peer-chat-left-a91f.txt
    peer-chat.py --to peer --message-file peer-chat-left-a91f.txt

--to peer (the default) is the other pane; --to left|right names a slot; --to claude|codex is the
legacy form and resolves to the one pane running that harness. The label is `Chat from <name>: `,
where the name is PEER_CHAT_NAME (set by peer-chat-spawn.sh) or `<harness> (<pane>)`.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any

HARNESSES = ("claude", "codex")
PANES = ("left", "right")
TARGETS = ("peer", *PANES, *HARNESSES)
ENGINE_NAMES = ("vendor/peer-chat.py", "peer-chat-engine.py")


def load_engine() -> ModuleType:
    here = Path(__file__).resolve().parent
    override = os.environ.get("PEER_CHAT_ENGINE")
    candidates = (
        [Path(override)] if override else [here / name for name in ENGINE_NAMES]
    )
    path = next((candidate for candidate in candidates if candidate.is_file()), None)
    if path is None:
        raise SystemExit(
            "peer-chat: the vendored engine is missing beside peer-chat.py; "
            "run peer-chat-install.sh"
        )
    spec = importlib.util.spec_from_file_location("peer_chat_engine", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


engine = load_engine()


@dataclass(frozen=True)
class Peer:
    window: str
    session: str
    profile: Any
    sender: str


def own_pane() -> str:
    pane = os.environ.get("AGTERM_PANE", "")
    if pane not in PANES:
        raise RuntimeError(
            f"AGTERM_PANE is {pane!r}, not left or right; send from a pane of an agterm split"
        )
    return pane


def other_pane(pane: str) -> str:
    return "right" if pane == "left" else "left"


def pane_foreground(info: dict[str, Any], pane: str) -> Any:
    return info.get("foreground" if pane == "left" else "splitForeground")


def harness_command(harness: str) -> str:
    configured = os.environ.get(f"PEER_CHAT_{harness.upper()}_COMMAND")
    return engine.command_name(configured or harness)


def detect_harness(info: dict[str, Any], pane: str) -> tuple[str, str] | None:
    foreground = pane_foreground(info, pane)
    for harness in HARNESSES:
        command = harness_command(harness)
        if engine.runs(foreground, command):
            return harness, command
    return None


def panes_running(info: dict[str, Any], command: str) -> list[str]:
    return [pane for pane in PANES if engine.runs(pane_foreground(info, pane), command)]


def candidate_windows(session: str | None, window: str | None) -> list[str]:
    pinned = window is not None or session is None
    return [engine.resolve_window(window)] if pinned else engine.open_window_ids()


def locate_session(session: str | None, window: str | None) -> dict[str, Any]:
    selector = engine.configured_selector(session, "AGTERM_SESSION_ID", "session")
    if not selector:
        raise RuntimeError(
            "no agterm session: send from an agterm pane or pass --session ID"
        )
    needle = selector.lower()
    matches = [
        info
        for candidate in candidate_windows(session, window)
        for info in engine.walk(engine.tree(candidate))
        if str(info.get("id", "")).lower().startswith(needle)
    ]
    if len(matches) != 1:
        detail = "ambiguous" if matches else "not found"
        raise RuntimeError(f"agterm session {selector!r} is {detail}")
    if not matches[0].get("hasSplit"):
        raise RuntimeError(f"session {selector} has no split, so there is no peer pane")
    return matches[0]


def target_pane(to: str, info: dict[str, Any], own: str, command: str | None) -> str:
    if to == "peer":
        return other_pane(own)
    if to in PANES:
        return to
    running = panes_running(info, command or harness_command(to))
    if len(running) != 1:
        raise RuntimeError(
            f"{len(running)} panes run {to}; address the peer with --to peer or --to left|right"
        )
    return running[0]


def recipient(
    to: str, info: dict[str, Any], pane: str, command: str | None
) -> tuple[str, str]:
    if command:
        return to, command
    detected = detect_harness(info, pane)
    if detected is None:
        raise RuntimeError(
            f"the {pane} pane runs no known peer ({', '.join(HARNESSES)}); for a wrapper set "
            "PEER_CHAT_<HARNESS>_COMMAND or pass --to <harness> --target-command NAME"
        )
    return detected


def sender_name(info: dict[str, Any], own: str) -> str:
    configured = " ".join(os.environ.get("PEER_CHAT_NAME", "").split())
    if configured:
        return configured
    detected = detect_harness(info, own)
    return f"{detected[0] if detected else 'peer'} ({own})"


def resolve_peer(
    to: str,
    session: str | None,
    window: str | None,
    command: str | None,
    queue: bool,
) -> Peer:
    own = own_pane()
    info = locate_session(session, window)
    pane = target_pane(to, info, own, command)
    if pane == own:
        raise RuntimeError(
            f"--to {to} resolves to this pane ({own}); the peer is the other one"
        )
    harness, executable = recipient(to, info, pane, command)
    if queue and harness != "codex":
        raise RuntimeError("--queue works only when the recipient runs codex")
    label = f"Chat from {sender_name(info, own)}: "
    profile = engine.Profile(pane, harness, executable, label, "\t" if queue else "\n")
    resolved_window, sid = engine.resolve_target(session, window, profile)
    return Peer(resolved_window, sid, profile, own)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", choices=TARGETS, default="peer")
    parser.add_argument("--session", type=engine.selector_argument)
    parser.add_argument("--window", type=engine.selector_argument)
    parser.add_argument(
        "--target-command",
        type=engine.command_name,
        metavar="NAME",
        help="wrapper executable the recipient runs; needs --to claude|codex for its protocol",
    )
    parser.add_argument(
        "--queue",
        action="store_true",
        help="queue a message to a codex recipient with Tab instead of steering with Return",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--stdin", action="store_true")
    source.add_argument("--message-file", type=engine.message_name, metavar="NAME")
    source.add_argument("--prepare-message", type=engine.message_name, metavar="NAME")
    args = parser.parse_args(argv)
    if args.target_command and args.to not in HARNESSES:
        parser.error(
            "--target-command needs --to claude or --to codex to pick the protocol"
        )
    return args


def run_main(progress: Any) -> int:
    args = parse_args()
    if args.prepare_message:
        path = engine.prepare_message(args.prepare_message)
        print(json.dumps({"messageFile": str(path)}))
        return 0
    peer = resolve_peer(
        args.to, args.session, args.window, args.target_command, args.queue
    )
    message = engine.read_message(args.stdin, args.message_file)
    sent = engine.send_with_retry(
        peer.session, peer.profile, message, peer.window, progress
    )
    progress.phase = "confirmed"
    engine.report_success(sent)
    return 0


def main() -> int:
    progress = engine.DeliveryProgress()
    try:
        return run_main(progress)
    except KeyboardInterrupt as err:
        detail = str(err) or {
            "confirmed": "delivery was confirmed; do not resend; success report interrupted",
            "started": "delivery status is unavailable; do not resend",
            "not_started": "nothing was typed",
        }.get(progress.phase, "")
        print(
            f"peer-chat: interrupted{': ' + detail if detail else ''}", file=sys.stderr
        )
        return 130
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as err:
        if progress.phase == "confirmed":
            print(
                f"peer-chat: delivery was confirmed; do not resend; success report failed: {err}",
                file=sys.stderr,
            )
            return 1
        print(f"peer-chat: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
