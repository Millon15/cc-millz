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

A send carrying --slug or --queue is handed, argv unchanged, to the sibling peer-chat-paste.py:
the ask ledger and the Tab queue live there, and this keystroke engine cannot type into the
composer of a mid-turn Codex, the one screen --queue exists for. The spool reservation step,
--prepare-message, sends nothing: it never hands off and ignores both flags.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any, NoReturn

HARNESSES = ("claude", "codex")
PANES = ("left", "right")
TARGETS = ("peer", *PANES, *HARNESSES)
ENGINE_NAMES = ("vendor/peer-chat.py", "peer-chat-engine.py")
PASTE_SCRIPT = "peer-chat-paste.py"
PASTE_FLAGS = ("--slug", "--queue", "--state", "--blocking", "--deadline", "--grace", "--wake",
               "--est-deadline", "--est-grace", "--est-wake", "--key")
PREPARE_FLAG = "--prepare-message"


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
    profile: BoundProfile
    sender: str
    session_info: dict[str, Any]


@dataclass(frozen=True)
class BoundProfile(engine.Profile):
    pane_id: str


def agterm_ctl(*args: str, input_text: str | None = None) -> str:
    socket = os.environ.get("AGTERM_SOCKET")
    return upstream_ctl(*args, *(("--socket", socket) if socket else ()), input_text=input_text)


def pane_id(info: dict[str, Any], role: str) -> str:
    for surface in info.get("surfaces", []):
        if surface.get("kind") == role and surface.get("paneID"):
            return surface["paneID"]
    raise RuntimeError(f"the {role} pane has no live pane id")


def pane_role(info: dict[str, Any], token: str) -> str:
    for surface in info.get("surfaces", []):
        if surface.get("paneID") == token and surface.get("kind") in PANES:
            return surface["kind"]
    raise RuntimeError(f"unknown pane id: {token}")


def require_bound_target(sid: str, profile: BoundProfile, window: str | None = None) -> str:
    info = engine.find_node(sid, window)
    role = pane_role(info, profile.pane_id)
    if not engine.runs(pane_foreground(info, role), profile.command):
        raise RuntimeError(f"the bound {profile.agent} pane is not running {profile.command!r}")
    return str(info["id"])


def bound_text(sid: str, profile: BoundProfile, window: str | None = None) -> str:
    return agterm_ctl("session", "text", "--pane-id", profile.pane_id, "--target", sid,
                      "--lines", str(engine.BOX_LINES), *engine.window_option(window))


def bound_cursor(sid: str, profile: BoundProfile, window: str | None = None) -> int:
    value = agterm_ctl("surface", "cursor", "--pane-id", profile.pane_id, "--target", sid,
                       *engine.window_option(window)).strip()
    try:
        return int(value)
    except ValueError as error:
        raise RuntimeError(f"surface cursor returned {value!r}") from error


def bound_type(sid: str, profile: BoundProfile, text: str, window: str | None = None) -> None:
    require_bound_target(sid, profile, window)
    agterm_ctl("session", "type", "--stdin", "--pane-id", profile.pane_id, "--target", sid,
               *engine.window_option(window), input_text=text)


CODEX_HOOK_EVENT_HEADER = re.compile(r"^\s*Event\s+(?:Active/Installed|Installed\s+Active)\b")
CODEX_HOOK_EVENT_ROW = re.compile(r"^\S+\s{2,}\d+(?:/|\s|$)")
CODEX_HOOK_HANDLER_ROW = re.compile(r"^\[[ x!]\]\s+\d+\s{2,}")
CODEX_HOOK_HANDLER_FOOTER = re.compile(r"(?:^| · )\S+ back\s*$")


def codex_hooks_browser(screen: str) -> bool:
    """The /hooks table prefixes its selected row with the composer glyph."""
    lines = screen.rstrip().splitlines()[-engine.BOX_LINES:]
    for index in range(len(lines) - 1, -1, -1):
        selected = engine.CODEX_PROMPT_RE.match(lines[index])
        if selected:
            row = selected.group(1)
            if CODEX_HOOK_EVENT_ROW.match(row):
                return any(CODEX_HOOK_EVENT_HEADER.match(line) for line in lines[:index])
            return bool(CODEX_HOOK_HANDLER_ROW.match(row) and CODEX_HOOK_HANDLER_FOOTER.search(lines[-1].strip()))
    return False


def live_prompt_text(profile: BoundProfile, screen: str) -> str | None:
    if profile.agent == "codex" and codex_hooks_browser(screen):
        return None
    return upstream_live_prompt_text(profile, screen)


# The vendored composer protocol uses the adapter's routing at its I/O boundaries.
upstream_ctl = engine.ctl
upstream_live_prompt_text = engine.live_prompt_text
engine.ctl = agterm_ctl
engine.require_target = require_bound_target
engine._pane_text_unchecked = bound_text
engine._cursor_column_unchecked = bound_cursor
engine.type_text = bound_type
engine.live_prompt_text = live_prompt_text


def own_pane(info: dict[str, Any]) -> str:
    token = os.environ.get("AGTERM_PANE_ID")
    if token and str(info["id"]).lower() == os.environ.get("AGTERM_SESSION_ID", "").lower():
        return pane_role(info, token)
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


def locate_session(session: str | None, window: str | None) -> tuple[str, dict[str, Any]]:
    selector = engine.configured_selector(session, "AGTERM_SESSION_ID", "session")
    if not selector:
        raise RuntimeError(
            "no agterm session: send from an agterm pane or pass --session ID"
        )
    needle = selector.lower()
    matches = [
        (candidate, info)
        for candidate in candidate_windows(session, window)
        for info in engine.walk(engine.tree(candidate))
        if str(info.get("id", "")).lower().startswith(needle)
    ]
    if len(matches) != 1:
        detail = "ambiguous" if matches else "not found"
        raise RuntimeError(f"agterm session {selector!r} is {detail}")
    resolved_window, info = matches[0]
    if not info.get("hasSplit"):
        raise RuntimeError(f"session {selector} has no split, so there is no peer pane")
    return resolved_window, info


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
    resolved_window, info = locate_session(session, window)
    own = own_pane(info)
    pane = target_pane(to, info, own, command)
    if pane == own:
        raise RuntimeError(
            f"--to {to} resolves to this pane ({own}); the peer is the other one"
        )
    harness, executable = recipient(to, info, pane, command)
    if queue and harness != "codex":
        raise RuntimeError("--queue works only when the recipient runs codex")
    label = f"Chat from {sender_name(info, own)}: "
    profile = BoundProfile(pane, harness, executable, label, "\t" if queue else "\n", pane_id(info, pane))
    return Peer(resolved_window, str(info["id"]), profile, own, info)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        epilog=f"--slug and --queue hand the whole send, argv unchanged, to {PASTE_SCRIPT}; "
        f"{PREPARE_FLAG} ignores both"
    )
    parser.add_argument("--to", choices=TARGETS, default="peer")
    parser.add_argument("--session", type=engine.selector_argument)
    parser.add_argument("--window", type=engine.selector_argument)
    parser.add_argument(
        "--target-command",
        type=engine.command_name,
        metavar="NAME",
        help="wrapper executable the recipient runs; needs --to claude|codex for its protocol",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--stdin", action="store_true")
    source.add_argument("--message-file", type=engine.message_name, metavar="NAME")
    source.add_argument(PREPARE_FLAG, type=engine.message_name, metavar="NAME")
    parser.add_argument("--slug", help=argparse.SUPPRESS)
    parser.add_argument("--queue", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not args.prepare_message and (args.slug is not None or args.queue):
        parser.error(f"spell --slug and --queue in full: either hands the send to {PASTE_SCRIPT}")
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
    peer = resolve_peer(args.to, args.session, args.window, args.target_command, False)
    message = engine.read_message(args.stdin, args.message_file)
    sent = engine.send_with_retry(
        peer.session, peer.profile, message, peer.window, progress
    )
    progress.phase = "confirmed"
    engine.report_success(sent)
    return 0


def prepares_message(argv: list[str]) -> bool:
    return any(arg == PREPARE_FLAG or arg.startswith(f"{PREPARE_FLAG}=") for arg in argv)


def hands_to_paste(argv: list[str]) -> bool:
    """A send carrying --slug or --queue; the spool reservation step sends nothing and stays here."""
    if prepares_message(argv):
        return False
    return any(arg.split("=", 1)[0] in PASTE_FLAGS for arg in argv)


def hand_to_paste(argv: list[str]) -> NoReturn:
    """Replace this process with the sibling paste transport, resolving through this adapter."""
    adapter = Path(__file__).resolve()
    paste = adapter.parent / PASTE_SCRIPT
    if not paste.is_file():
        raise SystemExit(
            f"peer-chat: {PASTE_SCRIPT} is missing beside peer-chat.py; run peer-chat-install.sh"
        )
    os.environ.setdefault("PEER_CHAT_TRANSPORT", str(adapter))
    os.execv(sys.executable, [sys.executable, str(paste), *argv])


def main() -> int:
    if hands_to_paste(sys.argv[1:]):
        hand_to_paste(sys.argv[1:])
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
