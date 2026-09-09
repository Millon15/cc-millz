#!/usr/bin/env python3
"""peer-chat-paste: a multi-line send, for a message the user reads in a thin pane.

peer-chat.py types the body as keystrokes, and a typed newline submits, so it collapses every
message to one line. This companion keeps the line breaks: the body goes in through a bracketed
paste (`agtermctl session paste`, the system clipboard, saved and restored around the call), which
both TUIs insert as multi-line composer text without submitting. It reuses peer-chat.py's own
target resolution and composer checks by loading the installed script as a module.

    peer-chat-paste.py --to codex --stdin < message.txt
    peer-chat-paste.py --to claude --message-file peer-chat-codex-a91f.txt   # from --prepare-message

--message-file is peer-chat.py's own spool contract: the name a `peer-chat.py --prepare-message`
call printed, consumed on read.

Guards, in order: the target pane runs the expected agent; its composer is empty; after the
paste the pane shows the message's last line (or the TUI's collapsed-paste marker); after the
submit key the composer is empty again. Any failure stops before the next step and reports it.
Nothing is ever typed into a composer that is not empty. Exit 0 sent, 1 refused or failed,
2 usage.
"""

from __future__ import annotations

import argparse
import os
import runpy
import shutil
import subprocess
import sys
import time
import unicodedata
from typing import Any

PASTE_SETTLE = 0.4
PASTE_TIMEOUT = float(os.environ.get("PEER_CHAT_PASTE_TIMEOUT", "8"))
ACCEPT_TIMEOUT = float(os.environ.get("PEER_CHAT_ACCEPT_TIMEOUT", "8"))
PROBE = 0.15
COLLAPSED_PASTE_MARKERS = ("[Pasted Content", "[Pasted text")


def load_transport() -> dict[str, Any]:
    path = os.environ.get("PEER_CHAT_TRANSPORT") or shutil.which("peer-chat.py")
    if not path:
        raise RuntimeError("peer-chat.py not on PATH; run peer-chat-install.sh first")
    return runpy.run_path(path, run_name="peer_chat_transport")


def shape(profile: Any, raw: str) -> str:
    lines = [line.rstrip() for line in raw.strip("\n").splitlines()]
    while lines and not lines[-1]:
        lines.pop()
    text = "\n".join(lines)
    if any(unicodedata.category(c) == "Cc" and c != "\n" for c in text):
        raise ValueError("chat message contains a control character")
    prefix = profile.label.strip()
    while text.lower().startswith(prefix.lower()):
        text = text[len(prefix) :].lstrip(": ").lstrip()
    if not text.strip():
        raise ValueError("chat message is empty")
    return profile.label + text


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


def send(t: dict[str, Any], args: argparse.Namespace, body: str) -> int:
    profile = t["target_profile"](args.to, args.target_command, False)
    window, sid = t["resolve_target"](args.session, args.window, profile)
    if not composer_empty_now(t, sid, profile, window):
        print(
            f"refused: the {profile.agent} composer is not empty; nothing written",
            file=sys.stderr,
        )
        return 1
    message = shape(profile, body)
    saved = clipboard_get()
    clipboard_set(message)
    try:
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
        t["type_text"](sid, profile, profile.submit, window)
        if not wait_until(
            lambda: composer_empty_now(t, sid, profile, window), ACCEPT_TIMEOUT
        ):
            print(
                "submit not confirmed: the composer did not clear; read the pane, never resend blind",
                file=sys.stderr,
            )
            return 1
    finally:
        if saved is not None:
            try:
                clipboard_set(saved)
            except (OSError, subprocess.CalledProcessError):
                pass
    print(f'{{"sent": {len(message)}, "lines": {message.count(chr(10)) + 1}}}')
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", required=True, choices=("claude", "codex"))
    parser.add_argument("--session")
    parser.add_argument("--window")
    parser.add_argument("--target-command")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--stdin", action="store_true")
    source.add_argument("--message-file")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    try:
        transport = load_transport()
        body = transport["read_message"](args.stdin, args.message_file)
        return send(transport, args, body)
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
