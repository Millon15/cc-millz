# Shared peer-chat protocol primitives. Canonical source: shared/peer-chat/peer_chat_core.py.
# Packaged into each plugin by scripts/sync-peer-chat-shared.py; edit the canonical file only.
from __future__ import annotations

import fcntl
import os
import re
import subprocess
import textwrap
import unicodedata
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

WRAP = int(os.environ.get("PEER_CHAT_WRAP", "50"))
DEFER_MINUTES = int(os.environ.get("PEER_CHAT_DEFER_MINUTES", "20"))
CONTINUATION_INDENT = "   "
ASK_GLYPH = "❓"
EVIDENCE_GLYPH = "🔎"
LEGACY_OWNER = {"claude": "left", "codex": "right"}
ASK_ID_RE = re.compile(r"#(left|right|claude|codex)-(\d{3,})")
DISPOSITION_RE = re.compile(
    r"#(?P<id>(?:left|right|claude|codex)-\d{3,})\s+(?P<kind>answered|deferred|declined)\b"
    r"[:(]?\s*(?P<reason>[^)]*?)\)?\s*$"
)
LEDGER_COLUMNS = ("id", "asked_by", "sent_at", "disposition", "due", "reason", "question")
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
        self._locked = False

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
        with self.locked():
            current = self.load()
            allocated = {ask.id for ask in current}
            if any(ask_id in allocated for ask_id, _ in plan.new_asks):
                raise LedgerRefusal("stale ask plan: an ID is already committed; inspect delivery before retrying")
            asks = self.apply_dispositions(current, plan.dispositions, moment)
            asks += [
                Ask(ask_id, sender, stamp(moment), OPEN, "", "", question)
                for ask_id, question in plan.new_asks
            ]
            self.write(asks)

    @contextmanager
    def locked(self):
        """Serialize planning through recording; nested use on this Ledger is safe."""
        if self._locked:
            yield self
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path.with_suffix(".lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self._locked = True
            try:
                yield self
            finally:
                self._locked = False
                fcntl.flock(lock, fcntl.LOCK_UN)

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


def drop_control(raw: str) -> str:
    """A tab becomes one space; CR and every other control character but newline is dropped."""
    kept = []
    for char in raw:
        if char == "\t":
            kept.append(" ")
        elif char == "\n" or unicodedata.category(char) != "Cc":
            kept.append(char)
    return "".join(kept)


def clean_lines(profile: Any, raw: str) -> list[str]:
    lines = [line.rstrip() for line in drop_control(raw).strip("\n").splitlines()]
    while lines and not lines[-1]:
        lines.pop()
    text = "\n".join(lines)
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
    lines: list[str], sender: str, ledger: Ledger | None, moment: datetime, width: int = WRAP
) -> Plan:
    plan = Plan(text="\n".join(lines), dispositions=parse_dispositions(lines))
    warn_ask_without_evidence(plan)
    if ledger is None:
        plan.warnings.append("warning: no --slug, so asks are not tracked in a ledger")
    else:
        refuse_missing_dispositions(ledger, sender, plan)
        assign_ask_ids(ledger, sender, plan)
        prepend_overdue(ledger, sender, plan, moment)
    plan.text = "\n".join(wrap_lines(plan.text.splitlines(), width))
    return plan
