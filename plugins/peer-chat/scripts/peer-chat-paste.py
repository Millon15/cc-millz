#!/usr/bin/env python3
"""peer-chat-paste: a multi-line send, for a message the user reads in a thin pane.

peer-chat.py types the body as keystrokes, and a typed newline submits, so it collapses every
message to one line. This companion keeps the line breaks: the body goes in through a bracketed
paste (`agtermctl session paste`, the system clipboard, saved and restored around the call), which
both TUIs insert as multi-line composer text without submitting. It reuses peer-chat.py's own
peer resolution by loading the installed script as a module.

    peer-chat-paste.py --to peer --stdin --slug <topic> < message.txt
    peer-chat-paste.py --to peer --message-file peer-chat-right-a91f.txt --slug <topic>

--message-file is peer-chat.py's own spool contract: the name a `peer-chat.py --prepare-message`
call printed, consumed on read.

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
import fcntl
import os
import re
import runpy
import shutil
import subprocess
import sys
import textwrap
import time
import unicodedata
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

PASTE_SETTLE = 0.4
PASTE_TIMEOUT = float(os.environ.get("PEER_CHAT_PASTE_TIMEOUT", "8"))
ACCEPT_TIMEOUT = float(os.environ.get("PEER_CHAT_ACCEPT_TIMEOUT", "8"))
WRAP = int(os.environ.get("PEER_CHAT_WRAP", "50"))
DEFER_MINUTES = int(os.environ.get("PEER_CHAT_DEFER_MINUTES", "20"))
PROBE = 0.15
COLLAPSED_PASTE_MARKERS = ("[Pasted Content", "[Pasted text")
CONTINUATION_INDENT = "   "
ASK_GLYPH = "❓"
EVIDENCE_GLYPH = "🔎"
TARGETS = ("peer", "left", "right", "claude", "codex")
LEGACY_OWNER = {"claude": "left", "codex": "right"}
ASK_ID_RE = re.compile(r"#(left|right|claude|codex)-(\d{3})")
DISPOSITION_RE = re.compile(
    r"#(?P<id>(?:left|right|claude|codex)-\d{3})\s+(?P<kind>answered|deferred|declined)\b"
    r"[:(]?\s*(?P<reason>[^)]*?)\)?\s*$"
)
LEDGER_COLUMNS = (
    "id",
    "asked_by",
    "sent_at",
    "disposition",
    "due",
    "reason",
    "question",
)
OPEN = ""


class LedgerRefusal(Exception):
    """A send refused by the ask ledger; nothing was written to the pane."""


@dataclass(frozen=True)
class Ask:
    id: str
    asked_by: str
    sent_at: str
    disposition: str
    due: str
    reason: str
    question: str

    @classmethod
    def from_row(cls, row: str) -> "Ask":
        cells = row.split("\t")
        cells += [""] * (len(LEDGER_COLUMNS) - len(cells))
        ask = cls(*cells[: len(LEDGER_COLUMNS)])
        return replace(ask, asked_by=LEGACY_OWNER.get(ask.asked_by, ask.asked_by))

    def row(self) -> str:
        return "\t".join(getattr(self, column) for column in LEDGER_COLUMNS)


@dataclass(frozen=True)
class Disposition:
    id: str
    kind: str
    reason: str


@dataclass
class Plan:
    text: str
    new_asks: list[tuple[str, str]] = field(default_factory=list)
    dispositions: list[Disposition] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def stamp(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def peer_of(pane: str) -> str:
    return "right" if pane == "left" else "left"


# ------------------------------------------------------------------ ledger --


class Ledger:
    """`asks.tsv` for one topic: read whole, written whole under a lock."""

    def __init__(self, path: Path) -> None:
        self.path = path

    @classmethod
    def for_slug(cls, slug: str) -> "Ledger":
        return cls(repo_root() / "tmp" / "peer-chat" / slug / "asks.tsv")

    def load(self) -> list[Ask]:
        if not self.path.exists():
            return []
        rows = self.path.read_text(encoding="utf-8").splitlines()[1:]
        return [Ask.from_row(row) for row in rows if row.strip()]

    def open_new_from(self, agent: str) -> list[Ask]:
        return [a for a in self.load() if a.asked_by == agent and a.disposition == OPEN]

    def overdue_deferred_by(self, agent: str, moment: datetime) -> list[Ask]:
        peer = peer_of(agent)
        return [
            a
            for a in self.load()
            if a.asked_by == peer
            and a.disposition == "deferred"
            and a.due < stamp(moment)
        ]

    def next_id(self, agent: str) -> str:
        taken = [int(a.id.split("-")[1]) for a in self.load() if a.asked_by == agent]
        return f"{agent}-{max(taken, default=0) + 1:03d}"

    def record(self, sender: str, plan: Plan, moment: datetime) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path.with_suffix(".lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            asks = self.apply_dispositions(self.load(), plan.dispositions, moment)
            asks += [
                Ask(ask_id, sender, stamp(moment), OPEN, "", "", question)
                for ask_id, question in plan.new_asks
            ]
            self.write(asks)

    @staticmethod
    def apply_dispositions(
        asks: list[Ask], dispositions: list[Disposition], moment: datetime
    ) -> list[Ask]:
        by_id = {d.id: d for d in dispositions}
        due = stamp(moment + timedelta(minutes=DEFER_MINUTES))
        return [
            (
                replace(
                    a,
                    disposition=by_id[a.id].kind,
                    reason=by_id[a.id].reason,
                    due=due if by_id[a.id].kind == "deferred" else "",
                )
                if a.id in by_id
                else a
            )
            for a in asks
        ]

    def write(self, asks: list[Ask]) -> None:
        tmp = self.path.with_suffix(".tmp")
        lines = ["\t".join(LEDGER_COLUMNS)] + [a.row() for a in asks]
        tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.replace(tmp, self.path)


def repo_root() -> Path:
    probe = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode == 0 and probe.stdout.strip():
        return Path(probe.stdout.strip())
    return Path.cwd()


# -------------------------------------------------------------------- body --


def load_transport() -> dict[str, Any]:
    path = os.environ.get("PEER_CHAT_TRANSPORT") or shutil.which("peer-chat.py")
    if not path:
        raise RuntimeError("peer-chat.py not on PATH; run peer-chat-install.sh first")
    adapter = runpy.run_path(path, run_name="peer_chat_transport")
    return {**vars(adapter["engine"]), **adapter}


def clean_lines(profile: Any, raw: str) -> list[str]:
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
    return text.splitlines()


def parse_dispositions(lines: list[str]) -> list[Disposition]:
    found = []
    for line in lines:
        match = DISPOSITION_RE.search(line)
        if match:
            found.append(
                Disposition(match["id"], match["kind"], match["reason"].strip())
            )
    return found


def is_ask(line: str) -> bool:
    return line.lstrip().startswith(ASK_GLYPH)


def ask_without_id(line: str) -> bool:
    return is_ask(line) and not ASK_ID_RE.search(line)


def question_of(line: str) -> str:
    return line.lstrip()[len(ASK_GLYPH) :].strip()


def has_unbreakable_token(line: str, width: int) -> bool:
    return any(len(token) > width - len(CONTINUATION_INDENT) for token in line.split())


def wrap_line(line: str, width: int) -> list[str]:
    if width <= 0 or len(line) <= width or has_unbreakable_token(line, width):
        return [line]
    leading = line[: len(line) - len(line.lstrip(" "))]
    return textwrap.wrap(
        line.lstrip(" "),
        width=width,
        initial_indent=leading,
        subsequent_indent=CONTINUATION_INDENT,
        break_long_words=False,
        break_on_hyphens=False,
    )


def wrap_lines(lines: list[str], width: int) -> list[str]:
    return [piece for line in lines for piece in wrap_line(line, width)]


def refuse_missing_dispositions(ledger: Ledger, sender: str, plan: Plan) -> None:
    disposed = {d.id for d in plan.dispositions}
    missing = [a for a in ledger.open_new_from(peer_of(sender)) if a.id not in disposed]
    if not missing:
        return
    listed = "\n".join(f"  #{a.id}: {a.question}" for a in missing)
    raise LedgerRefusal(
        "refused: the peer's asks below have no disposition in this message; add one line each,\n"
        "  `#<id> answered`, `#<id> deferred(<when>)` or `#<id> declined(<why>)`, then resend\n"
        f"{listed}"
    )


def assign_ask_ids(ledger: Ledger, sender: str, plan: Plan) -> None:
    lines = plan.text.splitlines()
    for index, line in enumerate(lines):
        if not ask_without_id(line):
            continue
        ask_id = (
            ledger.next_id(sender) if not plan.new_asks else bump(plan.new_asks[-1][0])
        )
        plan.new_asks.append((ask_id, question_of(line)))
        lines[index] = line.replace(ASK_GLYPH, f"{ASK_GLYPH} #{ask_id}", 1)
    plan.text = "\n".join(lines)


def bump(ask_id: str) -> str:
    agent, number = ask_id.split("-")
    return f"{agent}-{int(number) + 1:03d}"


def prepend_overdue(ledger: Ledger, sender: str, plan: Plan, moment: datetime) -> None:
    overdue = ledger.overdue_deferred_by(sender, moment)
    if not overdue:
        return
    notice = [f"overdue: #{a.id} deferred({a.reason}): {a.question}" for a in overdue]
    plan.text = "\n".join(notice + [""] + plan.text.splitlines())


def warn_ask_without_evidence(plan: Plan) -> None:
    lines = plan.text.splitlines()
    if any(is_ask(line) for line in lines) and not any(
        EVIDENCE_GLYPH in line for line in lines
    ):
        plan.warnings.append(
            "warning: a ❓ with no 🔎 in the message; rule B: one check of your own before asking"
        )


def plan_body(
    lines: list[str], sender: str, ledger: Ledger | None, moment: datetime
) -> Plan:
    plan = Plan(text="\n".join(lines), dispositions=parse_dispositions(lines))
    warn_ask_without_evidence(plan)
    if ledger is None:
        plan.warnings.append("warning: no --slug, so asks are not tracked in a ledger")
    else:
        refuse_missing_dispositions(ledger, sender, plan)
        assign_ask_ids(ledger, sender, plan)
        prepend_overdue(ledger, sender, plan, moment)
    plan.text = "\n".join(wrap_lines(plan.text.splitlines(), WRAP))
    return plan


# -------------------------------------------------------------------- pane --


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
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str
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
    t["type_text"](sid, profile, profile.submit, window)
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
    t: dict[str, Any], sid: str, profile: Any, window: str, message: str
) -> int:
    saved = clipboard_get()
    clipboard_set(message)
    try:
        return paste_and_submit(t, sid, profile, window, message)
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
        args.to, args.session, args.window, args.target_command, False
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
    moment = now_utc()
    plan = plan_body(clean_lines(profile, body), sender, ledger, moment)
    for warning in plan.warnings:
        print(warning, file=sys.stderr)
    message = profile.label + plan.text
    status = deliver(t, sid, profile, window, message)
    if status != 0:
        return status
    if ledger is not None:
        ledger.record(sender, plan, moment)
    report(message, plan)
    return 0


def restore_message_file(t: dict[str, Any], name: str, body: str) -> None:
    path = t["prepare_message"](name)
    path.write_text(body, encoding="utf-8")
    print(f"message file restored: {name}; fix the body and resend", file=sys.stderr)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", choices=TARGETS, default="peer")
    parser.add_argument("--session")
    parser.add_argument("--window")
    parser.add_argument("--target-command")
    parser.add_argument("--slug", default=os.environ.get("PEER_CHAT_SLUG") or None)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--stdin", action="store_true")
    source.add_argument("--message-file")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    try:
        transport = load_transport()
        body = transport["read_message"](args.stdin, args.message_file)
    except (RuntimeError, ValueError, OSError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        return 1
    try:
        return send(transport, args, body)
    except LedgerRefusal as refusal:
        print(f"peer-chat-paste: {refusal}", file=sys.stderr)
        if args.message_file:
            restore_message_file(transport, args.message_file, body)
        return 1
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as err:
        print(f"peer-chat-paste: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
