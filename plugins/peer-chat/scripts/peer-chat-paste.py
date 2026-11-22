#!/usr/bin/env python3
"""peer-chat-paste: a multi-line send, for a message the user reads in a thin pane.

peer-chat.py types the body as keystrokes, and a typed newline submits, so it collapses every
message to one line. This companion keeps the line breaks: the body goes in as one bracketed
paste typed through `agtermctl session type --stdin` (ESC[200~, the body, ESC[201~), which both
TUIs insert as multi-line composer text without submitting. The system clipboard is never touched,
so a sandboxed sender that cannot run pbcopy still sends. It reuses peer-chat.py's own
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
a disposition; the delivery lock frees within PEER_CHAT_LOCK_WAIT seconds; the peer pane shows a
live composer (gate A: a dialog, an approval modal or an unrecognised screen holds the send before
anything is prepared or typed); after the paste the pane shows the message's last 48 non-whitespace
characters, whitespace ignored on both sides (or the TUI's collapsed-paste marker); before the
submit key two composer reads PROBE seconds apart, the second after the key is picked, both hold
them or the marker (gate B: a dialog that opened over the paste is waited out and the pair starts
again, a composer without the text is left untouched). A symlink at the delivery lock path is
refused, never followed. Gates A and B poll every PEER_CHAT_DELIVERY_POLL seconds on one budget: --wait, then
PEER_CHAT_DELIVERY_WAIT minutes, then `delivery_wait_minutes` in the coordinator's .peer-chat.json,
else 60 s; PEER_CHAT_COMPOSER_GATE=off skips both. A held send shows one agterm notice unless
--no-notify. Suggestions, existing drafts and cursor state never block delivery, and existing text
is not cleared before pasting. Success reports that paste was observed and the submit key was
sent, not that the target accepted the message. Exit 0 sent; 1 transport failure, or pasted and
not submitted; 2 usage or state refusal (a symlinked lock path included), a send held before
anything was typed.

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
from dataclasses import dataclass
import math
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import (  # noqa: E402
    WRAP, Plan, LedgerRefusal, now_utc, repo_root, clean_lines, drop_control, parse_dispositions,
    plan_body,
)
from peer_chat_state import (
    StateError, Store, bind_participant, claim_delivery, observe, open_topic,
    prepare_message, resolve_budgets,
)

PASTE_SETTLE = 0.4
PASTE_TIMEOUT = float(os.environ.get("PEER_CHAT_PASTE_TIMEOUT", "8"))
ACCEPT_TIMEOUT = float(os.environ.get("PEER_CHAT_ACCEPT_TIMEOUT", "8"))
PROBE = 0.15
PROBE_CHARS = 48
COLLAPSED_PASTE_MARKERS = ("[Pasted Content", "[Pasted text")
PASTE_START = "\x1b[200~"
PASTE_END = "\x1b[201~"
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
DEFAULT_WAIT_SECONDS = 60.0
DEFAULT_POLL_SECONDS = 5.0
DEFAULT_LOCK_SECONDS = 10.0
WAIT_RE = re.compile(r"(\d+(?:\.\d+)?)([smh])")
UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600}
GATE_ENV = "PEER_CHAT_COMPOSER_GATE"
HELD_NO_COMPOSER = (
    "held: the peer pane shows no live composer (a dialog is open); nothing typed; "
    "rerun this send, --wait <dur> to wait longer"
)
GATE_OFF_WARNING = "peer-chat-paste: PEER_CHAT_COMPOSER_GATE=off: the dialog checks are skipped"
HELD_LOCK = "held: an earlier send is waiting for the peer's composer; nothing typed"
NOT_SUBMITTED = "peer-chat-paste: pasted, not submitted: {}; read the pane before any resend"
NO_LIVE_COMPOSER = "the peer pane shows no live composer"
COMPOSER_LACKS_MESSAGE = "the composer does not hold the message"
NOTIFY_BODY = "message for {} held: the peer shows a dialog"
LOCK_SYMLINK = "delivery lock path is a symlink; inspect it before any send"
LOCK_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC


class DeliveryHeld(StateError):
    """Nothing was typed: the send waits on a dialog or on another send's lock."""


class NotSubmitted(Exception):
    """The paste landed, the submit key was not sent."""


@dataclass(frozen=True)
class Gate:
    """One wait budget shared by the composer checks before the paste and before the submit key."""

    enabled: bool
    deadline: float
    poll: float
    alert: Callable[[], None]

    def expired(self) -> bool:
        return time.monotonic() >= self.deadline

    def pause(self) -> None:
        time.sleep(max(0.0, min(self.poll, self.deadline - time.monotonic())))


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


def wait_until(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(PROBE)
    return False


def message_probe(message: str) -> str:
    """The message's last PROBE_CHARS non-whitespace characters, so a short last line carries the lines above it."""
    return without_whitespace(message)[-PROBE_CHARS:]


def pasted_visible(
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str
) -> bool:
    return holds_message(t["_pane_text_unchecked"](sid, profile, window), message)


def without_whitespace(text: str) -> str:
    return "".join(text.split())


def holds_message(content: str, message: str) -> bool:
    """The text shows the message's tail, re-wrapped or not, or a collapsed-paste marker."""
    probe = message_probe(message)
    return bool(probe) and probe in without_whitespace(content) or collapsed(content)


def codex_draft_text(t: dict[str, Any], screen: str, untouched: bool) -> str | None:
    """A Codex composer whose draft holds blank lines, which the strict reader cuts at the first one.

    On a screen we have not pasted into, a numbered row below the prompt is an overlay: no composer.
    """
    lines = screen.splitlines()[-t["BOX_LINES"]:]
    prompts = [index for index, line in enumerate(lines) if t["CODEX_PROMPT_RE"].match(line)]
    if not prompts:
        return None
    first = t["CODEX_PROMPT_RE"].match(lines[prompts[-1]]).group(1)
    below = lines[prompts[-1] + 1:]
    choice = t["CODEX_CHOICE_RE"]
    if choice.match(first) or untouched and any(choice.match(line.strip()) for line in below):
        return None
    if any(line.strip() and not line[:1].isspace() for line in below):
        return None
    return "\n".join(part for part in (first, *(line.strip() for line in below)) if part)


def composer_text(t: dict[str, Any], sid: str, profile: Any, window: str, untouched: bool = False) -> str | None:
    """The peer's live composer content, or None while a dialog or an unknown screen covers it."""
    screen = t["_pane_text_unchecked"](sid, profile, window)
    content = t["live_prompt_text"](profile, screen)
    if content is None and profile.agent == "codex":
        return codex_draft_text(t, screen, untouched)
    return content


def await_live_composer(t: dict[str, Any], sid: str, profile: Any, window: str, gate: Gate) -> None:
    """Gate A: hold the send, nothing prepared or typed, until the peer shows a live composer."""
    if not gate.enabled:
        return
    while composer_text(t, sid, profile, window, untouched=True) is None:
        if gate.expired():
            gate.alert()
            raise DeliveryHeld(HELD_NO_COMPOSER)
        gate.pause()


def submit_refusal(t: dict[str, Any], sid: str, profile: Any, window: str, message: str, gate: Gate) -> str | None:
    """Gate B: why the submit key must not be sent, or None when the composer holds the message."""
    if not gate.enabled:
        return None
    while (refusal := composer_refusal_now(t, sid, profile, window, message)) == NO_LIVE_COMPOSER:
        if gate.expired():
            gate.alert()
            return NO_LIVE_COMPOSER
        gate.pause()
    return refusal


def composer_refusal_now(t: dict[str, Any], sid: str, profile: Any, window: str, message: str) -> str | None:
    """One composer read: None when it holds the message, else why the key must not be sent yet."""
    content = composer_text(t, sid, profile, window)
    if content is None:
        return NO_LIVE_COMPOSER
    return None if holds_message(content, message) else COMPOSER_LACKS_MESSAGE


def gated_submit_key(
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str, queue: bool, gate: Gate
) -> str:
    """Gate B: the submit key, picked between two reads PROBE apart that both show the message in the composer."""
    while True:
        refusal = submit_refusal(t, sid, profile, window, message, gate)
        if refusal:
            raise NotSubmitted(refusal)
        key = submit_key(t, sid, profile, window, queue)
        if not gate.enabled:
            return key
        time.sleep(PROBE)
        second = composer_refusal_now(t, sid, profile, window, message)
        if second is None:
            return key
        if second == COMPOSER_LACKS_MESSAGE:
            raise NotSubmitted(second)
        if gate.expired():
            gate.alert()
            raise NotSubmitted(NO_LIVE_COMPOSER)


def composer_empty_now(t: dict[str, Any], sid: str, profile: Any, window: str) -> bool:
    state = t["composer_state"](sid, profile, window)
    return state is not None and t["composer_is_empty"](profile, state[0])


def labelled(profile: Any, text: str) -> str:
    """The exact bytes a send types, records and matches: the cleaned label, then the body."""
    return drop_control(profile.label).replace("\n", " ") + text


def paste_and_submit(
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str, queue: bool,
    gate: Gate, observed=None,
) -> int:
    t["type_text"](sid, profile, PASTE_START + message + PASTE_END, window)
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
    try:
        key = gated_submit_key(t, sid, profile, window, message, queue, gate)
    except NotSubmitted as refusal:
        print(NOT_SUBMITTED.format(refusal), file=sys.stderr)
        return 1
    t["type_text"](sid, profile, key, window)
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
    gate: Gate, observed=None,
) -> int:
    return paste_and_submit(t, sid, profile, window, message, queue, gate, observed)


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


def coordinator_profile(repo: Path) -> dict[str, Any]:
    profile_path = repo / ".peer-chat.json"
    try:
        profile = json.loads(profile_path.read_text()) if profile_path.exists() else {}
    except (ValueError, OSError) as error:
        raise StateError(f"cannot read coordinator profile {profile_path}: {error}") from error
    if not isinstance(profile, dict):
        raise StateError("coordinator profile must be a JSON object")
    return profile


def store_profile(store: Store) -> dict[str, Any]:
    return coordinator_profile(Path(store.read()["repo"]))


def message_budgets(args: argparse.Namespace, store: Store):
    profile = store_profile(store)
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


def positive_number(raw: Any, name: str) -> float:
    try:
        value = float(raw) if not isinstance(raw, bool) else math.nan
    except (TypeError, ValueError):
        value = math.nan
    if not (math.isfinite(value) and value > 0):
        raise StateError(f"{name} must be a positive number, got {raw!r}")
    return value


def env_seconds(name: str, default: float) -> float:
    raw = os.environ.get(name)
    return positive_number(raw, name) if raw else default


def wait_duration(raw: str) -> float:
    match = WAIT_RE.fullmatch(raw.strip())
    seconds = float(match.group(1)) * UNIT_SECONDS[match.group(2)] if match else 0.0
    if not (math.isfinite(seconds) and seconds > 0):
        raise argparse.ArgumentTypeError(f"takes a positive duration such as 90s, 20m or 1h, got {raw!r}")
    return seconds


def delivery_budget(args: argparse.Namespace, profile: dict[str, Any]) -> float:
    """--wait, then PEER_CHAT_DELIVERY_WAIT minutes, then delivery_wait_minutes, else 60 s."""
    if args.wait is not None:
        return args.wait
    if os.environ.get("PEER_CHAT_DELIVERY_WAIT"):
        return positive_number(os.environ["PEER_CHAT_DELIVERY_WAIT"], "PEER_CHAT_DELIVERY_WAIT") * 60
    if "delivery_wait_minutes" in profile:
        return positive_number(profile["delivery_wait_minutes"], "delivery_wait_minutes") * 60
    return DEFAULT_WAIT_SECONDS


def notify_held(t: dict[str, Any], sid: str, pane: str) -> None:
    try:
        t["ctl"]("notify", NOTIFY_BODY.format(pane), "--title", "peer-chat", "--target", sid)
    except (RuntimeError, OSError, subprocess.SubprocessError):
        print("peer-chat-paste: the held notice could not be shown", file=sys.stderr)


def delivery_gate(t: dict[str, Any], args: argparse.Namespace, profile: dict[str, Any], peer) -> Gate:
    alert = (lambda: None) if args.no_notify else (lambda: notify_held(t, peer.session, peer.profile.pane))
    enabled = os.environ.get(GATE_ENV) != "off"
    if not enabled:
        print(GATE_OFF_WARNING, file=sys.stderr)
    return Gate(
        enabled=enabled,
        deadline=time.monotonic() + delivery_budget(args, profile),
        poll=env_seconds("PEER_CHAT_DELIVERY_POLL", DEFAULT_POLL_SECONDS),
        alert=alert,
    )


def lock_within(handle, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise DeliveryHeld(HELD_LOCK) from None
            time.sleep(PROBE)


def open_lock(path: Path) -> int:
    """The lock file's descriptor; a symlink at the path is refused, never followed or created through."""
    try:
        return os.open(path, LOCK_FLAGS, 0o600)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise StateError(LOCK_SYMLINK) from None
        raise


@contextmanager
def delivery_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(open_lock(path), "a") as handle:
        lock_within(handle, env_seconds("PEER_CHAT_LOCK_WAIT", DEFAULT_LOCK_SECONDS))
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
    store = topic_store(args)
    if store is None:
        return send_untracked(t, args, peer, body)
    return send_tracked(t, args, peer, store, body)


def send_untracked(t: dict[str, Any], args: argparse.Namespace, peer, body: str) -> int:
    profile, window, sid = peer.profile, peer.window, peer.session
    plan = plan_body(clean_lines(profile, body), peer.sender, None, now_utc())
    for warning in plan.warnings:
        print(warning, file=sys.stderr)
    message = labelled(profile, plan.text)
    gate = delivery_gate(t, args, coordinator_profile(repo_root()), peer)
    await_live_composer(t, sid, profile, window, gate)
    warn_if_mid_turn(peer_turn(t, sid, profile, window))
    status = deliver(t, sid, profile, window, message, args.queue, gate)
    if status == 0:
        report(message, plan)
    return status


def send_tracked(t: dict[str, Any], args: argparse.Namespace, peer, store: Store, body: str) -> int:
    profile, window, sid = peer.profile, peer.window, peer.session
    bind_panes(t, store, peer)
    path = outbox_path(store.path.parent, sid, profile.pane)
    with delivery_lock(path.with_suffix(".delivery.lock")):
        require_reconciled(store, peer.sender, "")
        gate = delivery_gate(t, args, store_profile(store), peer)
        await_live_composer(t, sid, profile, window, gate)
        prepared, message = claim_outbox(args, store, peer, body, path)
        warn_if_mid_turn(peer_turn(t, sid, profile, window))
        result = deliver_claimed(t, args, store, peer, message, prepared["message_id"], gate)
        if result:
            return result
    report_tracked(store, prepared, message)
    return 0


def claim_outbox(args: argparse.Namespace, store: Store, peer, body: str, path: Path) -> tuple[dict, str]:
    """Prepare and claim the message, then record the exact text for --recover-delivery."""
    prepared = prepare_message(store, sender=peer.sender, lines=clean_lines(peer.profile, body),
                               key=args.key or uuid.uuid4().hex, budgets=message_budgets(args, store), width=WRAP)
    for warning in prepared["warnings"]:
        print(warning, file=sys.stderr)
    mid = prepared["message_id"]
    if not claim_delivery(store, mid):
        raise StateError("message already claimed; inspect its recorded delivery, never paste it again")
    message = labelled(peer.profile, prepared["text"])
    record_outbox(path, message)
    metadata = json.dumps({"message_id": mid, "state": str(store.path),
                           "sha256": hashlib.sha256(message.encode()).hexdigest()})
    record_outbox(path.with_suffix(".json"), metadata)
    return prepared, message


def deliver_claimed(t: dict[str, Any], args: argparse.Namespace, store: Store, peer, message: str,
                    mid: str, gate: Gate) -> int:
    try:
        result = deliver(t, peer.session, peer.profile, peer.window, message, args.queue, gate,
                         lambda event: observe(store, mid, event))
    except (OSError, RuntimeError, subprocess.CalledProcessError):
        observe(store, mid, "uncertain")
        raise
    if result:
        observe(store, mid, "uncertain")
    return result


def report_tracked(store: Store, prepared: dict, message: str) -> None:
    current = store.read()["messages"][prepared["message_id"]]
    print(json.dumps({"sent": len(message), "lines": message.count("\n") + 1, "message_id": prepared["message_id"],
                      "asks": ["#" + ask_id for ask_id in prepared["ask_ids"]],
                      "disposed": ["#" + item.id for item in parse_dispositions(prepared["text"].splitlines())],
                      "state": str(store.path), "submitted_at": current.get("submitted_at")}))


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
    parser.add_argument("--wait", type=wait_duration,
                        help="how long to wait for the peer's composer when a dialog covers it (90s, 20m, 1h)")
    parser.add_argument("--no-notify", action="store_true",
                        help="no agterm notice when the send is held; for a rerun of a message already notified")
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
