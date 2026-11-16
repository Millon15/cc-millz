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
sent, not that the target accepted the message. Exit 0 sent, 1 transport failure, 2 usage or state refusal.

The topic's `tmp/peer-chat/<slug>/state.json` stores atomic reservations and delivery observations:
every `❓` line gets a topic-scoped id named after the asker's pane (`#left-004`), and the peer's
next send must carry `#left-004 answered`, `#left-004 deferred(<when>)` or `#left-004
declined(<why>)` for each new ask, or it is refused. Ledgers written before the panes became the
identity keep their `#claude-NNN` / `#codex-NNN` ids, read as asked by left / right. A deferral past PEER_CHAT_DEFER_MINUTES is prepended to the deferrer's
next send as `overdue: #id`. There is no length cap: prose lines are wrapped at PEER_CHAT_WRAP
columns on word boundaries so the pane never breaks a word, and a token with no spaces stays whole.

Every send with --slug first records the exact pasted text in `outbox-<session>-<pane>.msg` beside
the ledger, keyed by the receiving session and pane. `--recover-delivery --slug <topic>` runs in the
receiving pane, under a separate transport lock, without holding state.lock: it presses Return on its own
composer only when two reads, the second right before the key, both show exactly the recorded
message, whitespace aside. A collapsed paste marker hides its text, so it is never matched; any
other text stays untouched. Exit 0 Return pressed, 1 left untouched, 3 nothing to recover; one
JSON line on stdout.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import runpy
import shutil
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from contextlib import contextmanager

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import (  # noqa: E402
    WRAP, Plan, LedgerRefusal, now_utc, repo_root, clean_lines, parse_dispositions, plan_body,
)
from peer_chat_state import (
    StateError, Store, bind_participant, claim_delivery, observe, open_topic,
    prepare_message, resolve_budgets,
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
RECOVER_NOTHING = 3
SESSION_ID_RE = re.compile(r"[A-Za-z0-9-]+")
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
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str, queue: bool,
    observed=None,
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
    if observed:
        observed("pasted")
    t["type_text"](sid, profile, submit_key(t, sid, profile, window, queue), window)
    if observed:
        observed("submit_sent")
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
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str, queue: bool,
    observed=None,
) -> int:
    saved = clipboard_get()
    clipboard_set(message)
    try:
        return paste_and_submit(t, sid, profile, window, message, queue, observed)
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


def topic_store(args: argparse.Namespace) -> Store | None:
    if not (args.slug or args.state):
        if args.blocking or args.key or any(getattr(args, name) for name in
                               ("deadline", "grace", "wake", "est_deadline", "est_grace", "est_wake")):
            raise StateError("blocking budgets require --slug or --state")
        return None
    if args.slug and not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", args.slug):
        raise StateError("slug must be a single topic name")
    path = Path(args.state).expanduser().resolve() if args.state else repo_root() / "tmp/peer-chat" / args.slug / "state.json"
    if path.name != "state.json":
        raise StateError("--state must name a topic's state.json")
    current = Store(path).read() if path.exists() else None
    slug = args.slug or (current or {}).get("slug")
    if not slug:
        raise StateError("a new topic requires --slug")
    coordinator = Path(current["repo"]) if current else repo_root().resolve()
    return open_topic(path, transport="agterm", slug=slug, host="agterm", repo=coordinator,
                      legacy_dir=path.parent)


def message_budgets(args: argparse.Namespace, store: Store):
    profile_path = Path(store.read()["repo"]) / ".peer-chat.json"
    try:
        profile = json.loads(profile_path.read_text()) if profile_path.exists() else {}
    except (ValueError, OSError) as error:
        raise StateError(f"cannot read coordinator profile {profile_path}: {error}") from error
    if not isinstance(profile, dict):
        raise StateError("coordinator profile must be a JSON object")
    return resolve_budgets("agterm", args.blocking,
                           flags={name: getattr(args, name) for name in ("deadline", "grace", "wake")},
                           estimates={name: getattr(args, "est_" + name) for name in ("deadline", "grace", "wake")},
                           env=os.environ, profile=profile)


def bind_panes(t: dict[str, Any], store: Store, peer) -> None:
    info = t["locate_session"](peer.session, peer.window)
    for role in ("left", "right"):
        detected = t["detect_harness"](info, role)
        if not detected:
            raise StateError(f"the {role} pane runs no known harness")
        bind_participant(store, role, {
            "agent_id": f"{peer.window}/{peer.session}/{role}", "harness": detected[0],
            "requested_model": None, "pane": role, "session": peer.session, "window": peer.window,
        })


@contextmanager
def delivery_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def require_reconciled(store: Store, sender: str, message_id: str) -> None:
    for message in store.read()["messages"].values():
        if message["message_id"] == message_id or message["sender"] != sender:
            continue
        if message.get("claim") and message["state"] in ("prepared", "pasted", "dispatching", "uncertain"):
            raise StateError("earlier delivery is unresolved; inspect its outbox before another send")


def send(t: dict[str, Any], args: argparse.Namespace, body: str) -> int:
    peer = t["resolve_peer"](
        args.to, args.session, args.window, args.target_command, args.queue
    )
    profile, window, sid, sender = peer.profile, peer.window, peer.session, peer.sender
    store = topic_store(args)
    if store is None:
        plan = plan_body(clean_lines(profile, body), sender, None, now_utc())
        for warning in plan.warnings:
            print(warning, file=sys.stderr)
        message = profile.label + plan.text
        warn_if_mid_turn(peer_turn(t, sid, profile, window))
        status = deliver(t, sid, profile, window, message, args.queue)
        if status == 0:
            report(message, plan)
        return status
    bind_panes(t, store, peer)
    path = outbox_path(store.path.parent, sid, profile.pane)
    with delivery_lock(path.with_suffix(".delivery.lock")):
        require_reconciled(store, sender, "")
        prepared = prepare_message(store, sender=sender, lines=clean_lines(profile, body),
                                   key=args.key or uuid.uuid4().hex, budgets=message_budgets(args, store), width=WRAP)
        for warning in prepared["warnings"]:
            print(warning, file=sys.stderr)
        mid = prepared["message_id"]
        if not claim_delivery(store, mid):
            raise StateError("message already claimed; inspect its recorded delivery, never paste it again")
        message = profile.label + prepared["text"]
        record_outbox(path, message)
        metadata = json.dumps({"message_id": mid, "state": str(store.path),
                               "sha256": hashlib.sha256(message.encode()).hexdigest()})
        record_outbox(path.with_suffix(".json"), metadata)
        warn_if_mid_turn(peer_turn(t, sid, profile, window))
        try:
            result = deliver(t, sid, profile, window, message, args.queue,
                             lambda event: observe(store, mid, event))
            if result:
                observe(store, mid, "uncertain")
                return result
        except (OSError, RuntimeError, subprocess.CalledProcessError):
            observe(store, mid, "uncertain")
            raise
    current = store.read()["messages"][mid]
    print(json.dumps({"sent": len(message), "lines": message.count("\n") + 1, "message_id": mid,
                      "asks": ["#" + ask_id for ask_id in prepared["ask_ids"]],
                      "disposed": ["#" + item.id for item in parse_dispositions(prepared["text"].splitlines())],
                      "state": str(store.path), "submitted_at": current.get("submitted_at")}))
    return 0


def outbox_path(directory: Path, sid: str, pane: str) -> Path:
    if not SESSION_ID_RE.fullmatch(sid):
        raise ValueError(f"session id {sid!r} cannot name an outbox file")
    return directory / f"outbox-{sid}-{pane}.msg"


def record_outbox(path: Path, message: str) -> None:
    """The exact text this send pastes, for the receiver's --recover-delivery."""
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(".tmp")
    fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(message)
    os.replace(pending, path)


def holds_exactly(content: str, message: str) -> bool:
    return " ".join(content.split()) == " ".join(message.split())


def own_composer(t: dict[str, Any], sid: str, profile: Any, window: str) -> str | None:
    return t["live_prompt_text"](profile, t["_pane_text_unchecked"](sid, profile, window))


def collapsed(content: str) -> bool:
    return any(marker in content for marker in COLLAPSED_PASTE_MARKERS)


def composer_refusal(t: dict[str, Any], profile: Any, content: str | None, message: str) -> tuple[int, str] | None:
    """Why Return must not be pressed on this composer, or None when it holds exactly the message."""
    if content is None:
        return 1, "composer unreadable; left untouched"
    if t["composer_is_empty"](profile, content):
        return RECOVER_NOTHING, "composer empty; nothing to recover"
    if collapsed(content):
        return 1, "composer shows a collapsed paste whose text cannot be checked; left untouched"
    if not holds_exactly(content, message):
        return 1, "composer holds other text; left untouched"
    return None


def own_target(t: dict[str, Any], args: argparse.Namespace) -> tuple[str, str, Any]:
    own = t["own_pane"]()
    detected = t["detect_harness"](t["locate_session"](args.session, args.window), own)
    if detected is None:
        raise RuntimeError(f"the {own} pane runs no known harness; nothing to recover")
    profile = t["Profile"](own, detected[0], detected[1], "", RETURN_KEY)
    window, sid = t["resolve_target"](args.session, args.window, profile)
    return window, sid, profile


def recover_result(recovered: bool, reason: str) -> None:
    print(f'{{"recovered": {str(recovered).lower()}, "reason": "{reason}"}}')


def recover_delivery(t: dict[str, Any], args: argparse.Namespace) -> int:
    window, sid, profile = own_target(t, args)
    store = topic_store(args)
    path = outbox_path(store.path.parent, sid, profile.pane)
    with delivery_lock(path.with_suffix(".delivery.lock")):
        return recover_locked(t, sid, profile, window, path, store)


def recover_locked(t: dict[str, Any], sid: str, profile: Any, window: str, path: Path, store: Store) -> int:
    """A transport lock preserves the outbox while the storage lock stays free."""
    if not path.is_file():
        recover_result(False, f"no recorded message for the {profile.pane} pane")
        return RECOVER_NOTHING
    message = read_message_path(str(path), t["MAX_MESSAGE_BYTES"])
    metadata = json.loads(path.with_suffix(".json").read_text()) if path.with_suffix(".json").exists() else None
    if metadata:
        if metadata.get("state") != str(store.path) or metadata.get("sha256") != hashlib.sha256(message.encode()).hexdigest():
            raise StateError("recorded outbox identity or bytes changed; inspect before recovery")
        record = store.read()["messages"].get(metadata.get("message_id"))
        if not record or record["recipient"] != profile.pane:
            raise StateError("recorded outbox does not belong to this recipient")
        if record.get("submitted_at"):
            recover_result(False, "submission already recorded; no second Return")
            return RECOVER_NOTHING
    for _ in range(2):
        refusal = composer_refusal(t, profile, own_composer(t, sid, profile, window), message)
        if refusal is not None:
            recover_result(False, refusal[1])
            return refusal[0]
    t["type_text"](sid, profile, RETURN_KEY, window)
    if metadata:
        observe(store, metadata["message_id"], "submit_sent")
    os.replace(path, path.with_suffix(".recovered"))
    recover_result(True, "return pressed on the recorded message")
    return 0


def restore_message_file(t: dict[str, Any], name: str, body: str) -> None:
    path = t["prepare_message"](name)
    path.write_text(body, encoding="utf-8")
    print(
        f"message file restored: {name}; inspect the failure and peer screen before retrying",
        file=sys.stderr,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--to", choices=TARGETS, default="peer")
    parser.add_argument("--session")
    parser.add_argument("--window")
    parser.add_argument("--target-command")
    parser.add_argument("--slug", default=os.environ.get("PEER_CHAT_SLUG") or None)
    parser.add_argument("--state", help="the coordinator topic's state.json")
    parser.add_argument("--key", help="stable idempotency key; replays never authorize another paste")
    parser.add_argument("--blocking", action="store_true")
    for name in ("deadline", "grace", "wake"):
        parser.add_argument("--" + name)
        parser.add_argument("--est-" + name)
    parser.add_argument(
        "--queue",
        action="store_true",
        help="codex recipient only: Tab queues the note behind a peer seen working; "
        "an idle or unreadable peer gets Return",
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--stdin", action="store_true")
    source.add_argument("--message-file")
    source.add_argument(
        "--recover-delivery",
        action="store_true",
        help="in the receiving pane: press Return only when the own composer holds exactly "
        "the message recorded for it under --slug",
    )
    args = parser.parse_args(argv)
    if not (args.stdin or args.message_file or args.recover_delivery):
        parser.error("one of --stdin, --message-file or --recover-delivery is required")
    if args.recover_delivery and not (args.slug or args.state):
        parser.error("--recover-delivery needs --slug or --state")
    return args


def main() -> int:
    args = parse_args()
    if args.recover_delivery:
        return run_recover(args)
    try:
        transport = load_transport()
        body = read_body(transport, args)
    except (RuntimeError, ValueError, OSError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        return 1
    try:
        status = send(transport, args, body)
    except StateError as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        status = 2
    except (LedgerRefusal, RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        status = 1
    if status != 0 and args.message_file and not is_message_path(args.message_file):
        try:
            restore_message_file(transport, args.message_file, body)
        except (RuntimeError, ValueError, OSError) as err:
            print(f"peer-chat-paste: could not restore message file: {err}", file=sys.stderr)
    return status


def run_recover(args: argparse.Namespace) -> int:
    try:
        return recover_delivery(load_transport(), args)
    except StateError as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        return 2
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
