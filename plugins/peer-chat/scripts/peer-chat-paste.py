#!/usr/bin/env python3
"""peer-chat-paste: a multi-line send, for a message the user reads in a thin pane.

peer-chat.py types the body as keystrokes, and a typed newline submits, so it collapses every
message to one line. This companion keeps the line breaks: the body goes in through a bracketed
paste (`agtermctl session paste`, the system clipboard, saved and restored around the call), which
both TUIs insert as multi-line composer text without submitting. It reuses peer-chat.py's own
peer resolution by loading the installed script as a module.

    peer-chat-paste.py --to peer --stdin --slug <topic> < message.txt
    peer-chat-paste.py --to peer --message-file tmp/peer-chat/<topic>/03-left-body.msg --slug <topic>
    peer-chat-paste.py --to peer --message-file peer-chat-right-a91f.txt --slug <topic>

--message-file takes two forms. A value with a `/` is a path: an owned regular file, no symlink, at
most MAX_MESSAGE_BYTES, read verbatim and kept, the form for a body that quotes code or a bot
comment (`$(...)`, `<(...)`, pipes) that a shell guard would block inside a heredoc. A bare name is
peer-chat.py's own spool contract: the name a `peer-chat.py --prepare-message` call printed,
consumed on read.

Before the paste the send reads the peer's screen: a mid-turn peer (`turn_state` says `working`)
gets a stderr warning that the send queues behind its current task, and the send proceeds.
--queue (a codex recipient only) submits with Tab, which queues the note behind that task, but
only when a second read, taken once the paste is confirmed, still shows `working`: a turn that
ended during the paste wait, an idle or an unreadable screen gets Return, because a Tab that does
not submit would leave the note in the composer while the send reports success.

Guards, in order: the target pane runs a known peer harness; every new ask from the peer carries
a disposition; after the paste the pane shows the message's last line (or the TUI's collapsed-paste
marker). Composer occupancy checks before paste and after submit are intentionally disabled for
both agents: suggestions, existing drafts, and cursor state do not block delivery. Existing text
is not cleared before pasting. Success reports that paste was observed and the submit key was
sent, not that the target accepted the message. Exit 0 sent, 1 refused or failed, 2 usage.

The ask ledger, `tmp/peer-chat/<slug>/asks.tsv` under the repo root, is the script's own state:
every `❓` line gets a topic-scoped id named after the asker's pane (`#left-004`), and the peer's
next send must carry `#left-004 answered`, `#left-004 deferred(<when>)` or `#left-004
declined(<why>)` for each new ask, or it is refused. Ledgers written before the panes became the
identity keep their `#claude-NNN` / `#codex-NNN` ids, read as asked by left / right. A deferral past PEER_CHAT_DEFER_MINUTES is prepended to the deferrer's
next send as `overdue: #id`. There is no length cap: prose lines are wrapped at PEER_CHAT_WRAP
columns on word boundaries so the pane never breaks a word, and a token with no spaces stays whole.
"""

from __future__ import annotations

import argparse
import errno
import os
import re
import runpy
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from contextlib import nullcontext

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import (  # noqa: E402
    WRAP, DEFER_MINUTES, CONTINUATION_INDENT, ASK_GLYPH, EVIDENCE_GLYPH,
    LEGACY_OWNER, ASK_ID_RE, DISPOSITION_RE, LEDGER_COLUMNS, OPEN,
    Ask, Disposition, Plan, Ledger, LedgerRefusal, now_utc, stamp, peer_of,
    repo_root, drop_control, clean_lines, parse_dispositions, is_ask,
    ask_without_id, question_of, has_unbreakable_token, wrap_line, wrap_lines,
    refuse_missing_dispositions, assign_ask_ids, bump, prepend_overdue,
    warn_ask_without_evidence, plan_body,
)

PASTE_SETTLE = 0.4
PASTE_TIMEOUT = float(os.environ.get("PEER_CHAT_PASTE_TIMEOUT", "8"))
ACCEPT_TIMEOUT = float(os.environ.get("PEER_CHAT_ACCEPT_TIMEOUT", "8"))
PROBE = 0.15
COLLAPSED_PASTE_MARKERS = ("[Pasted Content", "[Pasted text")
TARGETS = ("peer", "left", "right", "claude", "codex")
RETURN_KEY = "\n"
QUEUE_KEY = "\t"
TURN_WORKING = "working"
TURN_IDLE = "idle"
TURN_UNKNOWN = "unknown"
TIMER = r"\((?:\d+h\s)?(?:\d+m\s)?\d+s\s"
# Claude Code mid-turn: a spinner line `✻ Pouncing… (5m 3s · ↓ 19.7k tokens)` (the glyph cycles and
# the idle summary `✻ Baked for 1m 59s · done 23:38` reuses it, so the `…` plus the timer is the
# discriminator), or a running tool's `(ctrl+b to run in background)` hint.
CLAUDE_WORKING_RES = (
    re.compile(r"^\s*[✻✶✳✢·]\s+\S+(?:…|\.\.\.)\s+" + TIMER + r"·", re.MULTILINE),
    re.compile(r"\(ctrl\+b to run in background\)"),
)
# Codex mid-turn: `• Working (2m 30s • esc to interrupt)`; the screen keeps drawing the empty
# `› Ask Codex to do anything` prompt under it, so the prompt alone never means idle.
CODEX_WORKING_RES = (
    re.compile(
        r"^\s*•\s+Working\s+" + TIMER + r"•\s+esc to interrupt\)",
        re.IGNORECASE | re.MULTILINE,
    ),
)
WORKING_MARKERS = {"claude": CLAUDE_WORKING_RES, "codex": CODEX_WORKING_RES}
PROMPT_MARKERS = {
    "claude": re.compile(r"^\s*❯", re.MULTILINE),
    "codex": re.compile(r"^[›»]", re.MULTILINE),
}
MID_TURN_WARNING = (
    "peer-chat-paste: the peer is mid-turn; this send queues behind its current task"
)


# -------------------------------------------------------------------- body --


def load_transport() -> dict[str, Any]:
    path = os.environ.get("PEER_CHAT_TRANSPORT") or shutil.which("peer-chat.py")
    if not path:
        raise RuntimeError("peer-chat.py not on PATH; run peer-chat-install.sh first")
    adapter = runpy.run_path(path, run_name="peer_chat_transport")
    return {**vars(adapter["engine"]), **adapter}


def is_message_path(value: str | None) -> bool:
    return bool(value) and "/" in value


def read_message_path(value: str, limit: int) -> str:
    """An owned regular file, opened without following a symlink, at most `limit` bytes."""
    try:
        fd = os.open(value, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as err:
        if err.errno in (errno.ELOOP, errno.EMLINK):
            raise ValueError(
                "message path must be an owned regular file, not a symlink"
            ) from err
        raise
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError(
                "message path must be an owned regular file, not a symlink"
            )
        if info.st_size > limit:
            raise ValueError(f"message path exceeds {limit} bytes")
        return os.read(fd, info.st_size).decode("utf-8")
    finally:
        os.close(fd)


def read_body(t: dict[str, Any], args: argparse.Namespace) -> str:
    if is_message_path(args.message_file):
        return read_message_path(args.message_file, t["MAX_MESSAGE_BYTES"])
    return t["read_message"](args.stdin, args.message_file)


# -------------------------------------------------------------------- pane --


def turn_state(screen: str, agent: str) -> str:
    """`working`, `idle` or `unknown` from a pane screen; a marker miss degrades to `unknown`."""
    if agent not in WORKING_MARKERS:
        return TURN_UNKNOWN
    if any(marker.search(screen) for marker in WORKING_MARKERS[agent]):
        return TURN_WORKING
    if PROMPT_MARKERS[agent].search(screen):
        return TURN_IDLE
    return TURN_UNKNOWN


def peer_turn(t: dict[str, Any], sid: str, profile: Any, window: str) -> str:
    try:
        screen = t["_pane_text_unchecked"](sid, profile, window)
    except (RuntimeError, OSError, subprocess.CalledProcessError):
        return TURN_UNKNOWN
    return turn_state(screen, profile.agent)


def warn_if_mid_turn(turn: str) -> None:
    if turn == TURN_WORKING:
        print(MID_TURN_WARNING, file=sys.stderr)


def submit_key(
    t: dict[str, Any], sid: str, profile: Any, window: str, queue: bool
) -> str:
    """--queue reads the peer again after the paste: Tab only while its turn runs, else Return."""
    if not queue:
        return profile.submit
    return (
        QUEUE_KEY if peer_turn(t, sid, profile, window) == TURN_WORKING else RETURN_KEY
    )


def clipboard_get() -> str | None:
    try:
        return subprocess.run(
            ["pbpaste"], capture_output=True, text=True, check=False
        ).stdout
    except OSError:
        return None


def clipboard_set(text: str) -> None:
    subprocess.run(["pbcopy"], input=text, text=True, check=True)


def wait_until(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(PROBE)
    return False


def pasted_visible(
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str
) -> bool:
    text = t["_pane_text_unchecked"](sid, profile, window)
    tail = message.splitlines()[-1].strip()
    probe = tail[-24:] if len(tail) > 24 else tail
    if probe and probe in text:
        return True
    return any(marker in text for marker in COLLAPSED_PASTE_MARKERS)


def composer_empty_now(t: dict[str, Any], sid: str, profile: Any, window: str) -> bool:
    state = t["composer_state"](sid, profile, window)
    return state is not None and t["composer_is_empty"](profile, state[0])


def paste_and_submit(
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str, queue: bool
) -> int:
    t["ctl"](
        "session",
        "paste",
        "--pane",
        profile.pane,
        "--target",
        sid,
        *t["window_option"](window),
    )
    if not wait_until(
        lambda: pasted_visible(t, sid, profile, window, message), PASTE_TIMEOUT
    ):
        print(
            "paste not confirmed in the composer; read the pane before any resend",
            file=sys.stderr,
        )
        return 1
    time.sleep(PASTE_SETTLE)
    t["type_text"](sid, profile, submit_key(t, sid, profile, window, queue), window)
    # Post-submit occupancy check disabled too: new suggestions/drafts are not failures.
    # if not wait_until(
    #     lambda: composer_empty_now(t, sid, profile, window), ACCEPT_TIMEOUT
    # ):
    #     print(
    #         "submit not confirmed: the composer did not clear; read the pane, never resend blind",
    #         file=sys.stderr,
    #     )
    #     return 1
    return 0


def deliver(
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str, queue: bool
) -> int:
    saved = clipboard_get()
    clipboard_set(message)
    try:
        return paste_and_submit(t, sid, profile, window, message, queue)
    finally:
        if saved is not None:
            try:
                clipboard_set(saved)
            except (OSError, subprocess.CalledProcessError):
                pass


def report(message: str, plan: Plan) -> None:
    asks = ", ".join(f'"#{ask_id}"' for ask_id, _ in plan.new_asks)
    disposed = ", ".join(f'"#{d.id}"' for d in plan.dispositions)
    print(
        f'{{"sent": {len(message)}, "lines": {message.count(chr(10)) + 1}, '
        f'"asks": [{asks}], "disposed": [{disposed}]}}'
    )


def send(t: dict[str, Any], args: argparse.Namespace, body: str) -> int:
    peer = t["resolve_peer"](
        args.to, args.session, args.window, args.target_command, args.queue
    )
    profile, window, sid, sender = peer.profile, peer.window, peer.session, peer.sender
    # Occupancy preflight disabled by user request for both agents (2026-09-13).
    # if not composer_empty_now(t, sid, profile, window):
    #     print(
    #         f"refused: the {profile.agent} composer is not empty; nothing written",
    #         file=sys.stderr,
    #     )
    #     return 1
    ledger = Ledger.for_slug(args.slug) if args.slug else None
    # Legacy paste commits only after submission. Serialize its bounded transport call
    # with planning so concurrent sends cannot allocate the same ask ID or miss asks.
    with ledger.locked() if ledger is not None else nullcontext():
        moment = now_utc()
        plan = plan_body(clean_lines(profile, body), sender, ledger, moment)
        for warning in plan.warnings:
            print(warning, file=sys.stderr)
        message = profile.label + plan.text
        warn_if_mid_turn(peer_turn(t, sid, profile, window))
        status = deliver(t, sid, profile, window, message, args.queue)
        if status != 0:
            return status
        if ledger is not None:
            ledger.record(sender, plan, moment)
        report(message, plan)
        return 0


def restore_message_file(t: dict[str, Any], name: str, body: str) -> None:
    path = t["prepare_message"](name)
    path.write_text(body, encoding="utf-8")
    print(
        f"message file restored: {name}; inspect the failure and peer screen before retrying",
        file=sys.stderr,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", choices=TARGETS, default="peer")
    parser.add_argument("--session")
    parser.add_argument("--window")
    parser.add_argument("--target-command")
    parser.add_argument("--slug", default=os.environ.get("PEER_CHAT_SLUG") or None)
    parser.add_argument(
        "--queue",
        action="store_true",
        help="codex recipient only: Tab queues the note behind a peer seen working; "
        "an idle or unreadable peer gets Return",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--stdin", action="store_true")
    source.add_argument("--message-file")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    try:
        transport = load_transport()
        body = read_body(transport, args)
    except (RuntimeError, ValueError, OSError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        return 1
    try:
        status = send(transport, args, body)
    except (LedgerRefusal, RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        status = 1
    if status != 0 and args.message_file and not is_message_path(args.message_file):
        try:
            restore_message_file(transport, args.message_file, body)
        except (RuntimeError, ValueError, OSError) as err:
            print(f"peer-chat-paste: could not restore message file: {err}", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
