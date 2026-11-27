# Schema 2 topic state: one state.json per topic. Canonical source: shared/peer-chat/peer_chat_state.py.
# Packaged into each plugin by scripts/sync-peer-chat-shared.py; edit the canonical file only.
from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
import re
import subprocess
import tempfile
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping

from peer_chat_core import (
    DEFER_MINUTES,
    Ask,
    Disposition,
    Ledger,
    LedgerRefusal,
    Plan,
    now_utc,
    parse_dispositions,
    peer_of,
    plan_body,
    refuse_missing_dispositions,
    stamp,
    wrap_lines,
)

SCHEMA = 2
TRANSPORTS = ("agterm", "bg")
ROLES = ("left", "right")
EVIDENCE_DIR = "evidence"
CLOSED = ("answered", "declined", "withdrawn")
BUDGET_FIELDS = ("deadline", "grace", "wake")
ENV_NAMES = {
    "deadline": "PEER_CHAT_STALL_MINUTES",
    "grace": "PEER_CHAT_GRACE_MINUTES",
    "wake": "PEER_CHAT_WAKE_MINUTES",
}
PROFILE_KEYS = {
    "deadline": "stall_minutes",
    "grace": "grace_minutes",
    "wake": "wake_minutes",
}
NOTE_CLAUSES = {
    "deadline": "deadline {} after submission",
    "grace": "grace {} after nudge submission",
    "wake": "wake {}",
}
BUDGET_GLYPH = "⏱"
DURATION_RE = re.compile(r"(\d+(?:\.\d+)?)([smh])\Z")
UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600}
SUBMIT_EVENTS = ("submit_sent", "submitted")
PEER_EVENTS = ("acknowledged", "answered")
CLAIM_EVENTS = ("dispatching",)
IN_FLIGHT = (
    "prepared",
    "dispatching",
    "pasted",
    "submit_sent",
    "submitted",
    "uncertain",
)
TERMINAL_MESSAGES = ("acknowledged", "answered", "failed", "cancelled")
TRANSITIONS = {
    "agterm": {
        "prepared": {"pasted", "failed", "uncertain", "cancelled"},
        "pasted": {"submit_sent", "uncertain"},
        "submit_sent": {"acknowledged", "answered", "uncertain"},
        "uncertain": {"submit_sent", "acknowledged", "answered", "failed"},
        "acknowledged": {"answered"},
    },
    "bg": {
        "prepared": {"dispatching", "cancelled", "acknowledged", "answered"},
        "dispatching": {"submitted", "uncertain", "acknowledged", "answered", "failed"},
        "submitted": {"acknowledged", "answered", "uncertain"},
        "uncertain": {"submitted", "acknowledged", "answered", "failed"},
        "acknowledged": {"answered"},
    },
}
TIMER_ACTIONS = {"armed": "nudge", "nudged": "stop"}
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


class StateError(Exception):
    """A refusal: the state file is unchanged."""


def require(condition: Any, message: str) -> None:
    if not condition:
        raise StateError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_stamp(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=now_utc().tzinfo
    )


# ------------------------------------------------------------------- store --


class Store:
    """state.json for one topic; every write is one short lock and an atomic replace."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.lock_path = self.path.with_name("state.lock")

    def exists(self) -> bool:
        return self.path.is_file()

    def read(self) -> dict:
        require(self.exists(), f"topic does not exist: {self.path}")
        return json.loads(self.path.read_text(encoding="utf-8"))

    @contextmanager
    def mutate(self) -> Iterator[dict]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                state = self.read() if self.exists() else {}
                yield state
                self._write(state)
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def _write(self, state: dict) -> None:
        temp = self.path.with_name(".state-" + uuid.uuid4().hex + ".tmp")
        try:
            with temp.open("x", encoding="utf-8") as stream:
                os.chmod(temp, 0o600)
                json.dump(state, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, self.path)
        finally:
            temp.unlink(missing_ok=True)


# ------------------------------------------------------------ topic + migration --


def open_topic(
    path: Path,
    *,
    transport: str,
    slug: str,
    host: str,
    repo: Path,
    legacy_dir: Path | None = None,
    on_create: Callable[[dict], None] | None = None,
) -> Store:
    """Create or migrate the topic; on_create seeds a new state inside the same write, so no partial topic exists."""
    require(transport in TRANSPORTS, f"unknown transport: {transport}")
    store = Store(path)
    with store.mutate() as state:
        if not state:
            state.update(new_state(transport, slug, host, repo))
            if on_create:
                on_create(state)
        elif state.get("schema") == 1:
            migrate_bg_schema1(state, store.path, transport)
        require(
            state.get("schema") == SCHEMA,
            f"unsupported state schema: {state.get('schema')}",
        )
        require(
            state["transport"] == transport,
            f"topic runs on {state['transport']}; no transport switch mid-run",
        )
        require(state["slug"] == slug, "state file belongs to another slug")
        if legacy_dir is not None:
            import_legacy(state, Path(legacy_dir))
    return store


def new_state(transport: str, slug: str, host: str, repo: Path) -> dict:
    return {
        "schema": SCHEMA,
        "transport": transport,
        "run_id": uuid.uuid4().hex,
        "slug": slug,
        "repo": str(Path(repo).resolve()),
        "host": host,
        "created_at": stamp(now_utc()),
        "phase": "active",
        "migrations": [],
        "participants": {"left": None, "right": None},
        "counters": {"left": 0, "right": 0},
        "keys": {},
        "asks": [],
        "messages": {},
        "freezes": [],
        "checks": {},
        "confirmations": {},
        "timers": {},
    }


def migrate_bg_schema1(state: dict, path: Path, transport: str) -> None:
    require(transport == "bg", "a schema 1 state.json belongs to peer-chat-bg")
    source = sha256_bytes(path.read_bytes())
    legacy = dict(state)
    state.clear()
    state.update(new_state("bg", legacy["slug"], legacy["host"], Path(legacy["repo"])))
    state.update(
        {
            key: legacy[key]
            for key in (
                "run_id",
                "created_at",
                "phase",
                "counters",
                "keys",
                "checks",
                "confirmations",
            )
            if key in legacy
        }
    )
    state["participants"] = {
        role: bg_participant(binding, legacy["host"])
        for role, binding in legacy["bindings"].items()
    }
    state["asks"] = [ask_from_legacy(row) for row in legacy["asks"]]
    state["messages"] = {
        mid: message_from_legacy(message) for mid, message in legacy["messages"].items()
    }
    state["migrations"].append(migration("bg-schema-1", "state.json schema 1", source))


def bg_participant(binding: dict | None, host: str) -> dict | None:
    if binding is None:
        return None
    return {
        "agent_id": binding["agent_id"],
        "harness": host,
        "requested_model": None,
        "pane": None,
        "session": None,
        "window": None,
        "generation": binding.get("generation", 1),
    }


def ask_from_legacy(row: dict) -> dict:
    return {
        "id": row["id"],
        "asked_by": row["asked_by"],
        "sent_at": row["sent_at"],
        "disposition": row["disposition"],
        "deferred_due": row.get("due", ""),
        "reason": row["reason"],
        "question": row["question"],
        "blocking": False,
        "message_id": None,
        "timed_out": None,
    }


def message_from_legacy(message: dict) -> dict:
    events = [
        {
            "event": r["state"],
            "at": r["at"],
            "actor": r.get("actor_id"),
            "evidence": r.get("evidence"),
        }
        for r in message.get("receipts", [])
    ]
    claim = next(({"at": e["at"]} for e in events if e["event"] == "dispatching"), None)
    submitted = next((e["at"] for e in events if e["event"] == "submitted"), None)
    kept = {key: value for key, value in message.items() if key != "receipts"}
    return {
        **kept,
        "budgets": None,
        "budget_note": None,
        "claim": claim,
        "events": events,
        "submitted_at": submitted,
    }


def migration(kind: str, source: str, digest: str) -> dict:
    return {
        "id": f"{kind}-{digest[:12]}",
        "source": source,
        "sha256": digest,
        "at": stamp(now_utc()),
    }


def import_legacy(state: dict, legacy_dir: Path) -> None:
    import_asks_tsv(state, legacy_dir / "asks.tsv")
    import_freezes_tsv(state, legacy_dir / "freezes.tsv")


def import_asks_tsv(state: dict, path: Path) -> None:
    if not path.is_file():
        return
    digest = sha256_bytes(path.read_bytes())
    prior = [m for m in state["migrations"] if m["source"] == "asks.tsv"]
    if prior:
        require(
            prior[-1]["sha256"] == digest,
            "asks.tsv changed after its import into state.json; an old writer touched this topic, refusing",
        )
        return
    require(
        not state["asks"],
        "state.json already holds asks and asks.tsv was never imported; refusing to merge",
    )
    asks = Ledger(path).load()
    state["asks"] = [ask_from_legacy(vars(ask)) for ask in asks]
    for role in ROLES:
        numbers = [int(ask.id.split("-")[1]) for ask in asks if ask.asked_by == role]
        state["counters"][role] = max(numbers, default=0)
    state["migrations"].append(migration("asks-tsv", "asks.tsv", digest))


def import_freezes_tsv(state: dict, path: Path) -> None:
    if not path.is_file() or any(
        m["source"] == "freezes.tsv" for m in state["migrations"]
    ):
        return
    digest = sha256_bytes(path.read_bytes())
    for line in path.read_text(encoding="utf-8").splitlines():
        cells = line.split("\t") + ["", "", "", ""]
        state["freezes"].append(
            {
                "n": len(state["freezes"]) + 1,
                "repo": None,
                "tree": cells[2],
                "previous": None,
                "pathspecs": cells[3].split(),
                "at": cells[1],
                "legacy": True,
            }
        )
    state["migrations"].append(migration("freezes-tsv", "freezes.tsv", digest))


# ------------------------------------------------------------- participants --


def bind_participant(store: Store, role: str, identity: Mapping[str, Any]) -> dict:
    require(role in ROLES, f"unknown role: {role}")
    require(str(identity.get("agent_id") or "").strip(), "identity needs an agent_id")
    with store.mutate() as state:
        require(state["phase"] == "active", "topic is finalized; use a fresh slug")
        prior = state["participants"][role]
        require(
            not prior or prior["agent_id"] == identity["agent_id"],
            "role already bound to another identity; no silent replacement in an active run",
        )
        other = state["participants"][peer_of(role)]
        require(
            not other or other["agent_id"] != identity["agent_id"],
            "both roles cannot share one identity",
        )
        state["participants"][role] = participant_record(identity)
        return dict(state["participants"][role])


def participant_record(identity: Mapping[str, Any]) -> dict:
    keys = ("agent_id", "harness", "requested_model", "pane", "session", "window")
    return {**{key: identity.get(key) for key in keys}, "generation": 1}


# ----------------------------------------------------------------- budgets --


@dataclass(frozen=True)
class BudgetValue:
    seconds: float
    source: str


@dataclass(frozen=True)
class Budgets:
    deadline: BudgetValue
    grace: BudgetValue
    wake: BudgetValue | None

    def to_json(self) -> dict:
        return {
            name: value and {"seconds": value.seconds, "source": value.source}
            for name, value in self.fields()
        }

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> "Budgets":
        values = {
            name: data.get(name)
            and BudgetValue(float(data[name]["seconds"]), data[name]["source"])
            for name in BUDGET_FIELDS
        }
        return cls(**values)

    def fields(self) -> list[tuple[str, BudgetValue | None]]:
        return [(name, getattr(self, name)) for name in BUDGET_FIELDS]


def parse_duration(text: str) -> float:
    match = DURATION_RE.fullmatch(str(text).strip())
    require(match, f"malformed duration {text!r}: use 90s, 20m or 1h")
    return positive_seconds(float(match[1]) * UNIT_SECONDS[match[2]], text)


def minutes_to_seconds(value: Any, origin: str) -> float:
    require(not isinstance(value, bool), f"{origin}: minutes must be a number")
    try:
        minutes = float(value)
    except (TypeError, ValueError):
        raise StateError(f"{origin}: minutes must be a number, got {value!r}") from None
    return positive_seconds(minutes * 60, value)


def positive_seconds(seconds: float, origin: Any) -> float:
    require(
        math.isfinite(seconds) and seconds > 0,
        f"duration {origin!r} must be positive and finite",
    )
    return seconds


def resolve_budgets(
    transport: str,
    blocking: bool,
    *,
    flags: Mapping[str, str | None],
    estimates: Mapping[str, str | None],
    env: Mapping[str, str],
    profile: Mapping[str, Any],
) -> Budgets | None:
    if not blocking:
        return None
    names = BUDGET_FIELDS if transport == "agterm" else ("deadline", "grace")
    values = {
        name: resolve_value(name, flags, estimates, env, profile) for name in names
    }
    refuse_missing_budgets([name for name, value in values.items() if value is None])
    return Budgets(values["deadline"], values["grace"], values.get("wake"))


def refuse_missing_budgets(missing: list[str]) -> None:
    if not missing:
        return
    raise StateError(
        f"a blocking ask needs {', '.join(missing)}: pass the user's value as "
        f"--{missing[0]} or your estimate as --est-{missing[0]}"
    )


def resolve_value(name, flags, estimates, env, profile) -> BudgetValue | None:
    if flags.get(name):
        return BudgetValue(parse_duration(flags[name]), "flag")
    if env.get(ENV_NAMES[name]):
        return BudgetValue(
            minutes_to_seconds(env[ENV_NAMES[name]], ENV_NAMES[name]), "env"
        )
    if profile.get(PROFILE_KEYS[name]) is not None:
        return BudgetValue(
            minutes_to_seconds(profile[PROFILE_KEYS[name]], PROFILE_KEYS[name]),
            "profile",
        )
    if estimates.get(name):
        return BudgetValue(parse_duration(estimates[name]), "agent")
    return None


def format_duration(seconds: float) -> str:
    whole = int(seconds)
    if whole != seconds:
        return f"{seconds:g}s"
    if whole % 3600 == 0:
        return f"{whole // 3600}h"
    if whole % 60 == 0:
        return f"{whole // 60}m"
    return f"{whole}s"


def budget_note(budgets: Budgets) -> str:
    return "; ".join(
        f"{NOTE_CLAUSES[name].format(format_duration(value.seconds))} ({value.source})"
        for name, value in budgets.fields()
        if value is not None
    )


# ----------------------------------------------------------------- ledger --


class StateLedger(Ledger):
    """The core Ledger API read from state["asks"], so plan_body plans against schema 2."""

    def __init__(
        self, state: dict, sender: str | None = None, exclude_message: str | None = None
    ) -> None:
        super().__init__(Path(os.devnull))
        self.state = state
        self.pending = in_flight_dispositions(state, sender, exclude_message)

    def load(self) -> list[Ask]:
        return [
            Ask(
                a["id"],
                a["asked_by"],
                a["sent_at"],
                a["disposition"],
                a["deferred_due"],
                a["reason"],
                a["question"],
            )
            for a in self.state["asks"]
        ]

    def open_new_from(self, agent: str) -> list[Ask]:
        return [
            ask for ask in super().open_new_from(agent) if ask.id not in self.pending
        ]

    def next_id(self, agent: str) -> str:
        return f"{agent}-{self.state['counters'][agent] + 1:03d}"

    def record(self, *_args) -> None:
        raise StateError("StateLedger records through prepare_message, never directly")


def in_flight_dispositions(
    state: dict, sender: str | None, exclude_message: str | None
) -> set[str]:
    return {
        disposition.id
        for mid, message in state["messages"].items()
        if mid != exclude_message
        and message["sender"] == sender
        and message["state"] in IN_FLIGHT
        and not message["dispositions_applied"]
        for disposition in message_dispositions(message)
    }


def message_dispositions(message: dict) -> list[Disposition]:
    """The dispositions planned from the unwrapped lines; the wrapped display text is never re-parsed."""
    if "dispositions" in message:
        return [Disposition(**row) for row in message["dispositions"]]
    return parse_dispositions(message["text"].splitlines())


def validate_dispositions(
    state: dict, sender: str, dispositions: list[Disposition], allow_stale=False
) -> list[str]:
    asks = {ask["id"]: ask for ask in state["asks"]}
    seen: set[str] = set()
    stale = []
    for disposition in dispositions:
        require(disposition.id not in seen, f"duplicate disposition: {disposition.id}")
        seen.add(disposition.id)
        require(disposition.id in asks, f"unknown ask: {disposition.id}")
        ask = asks[disposition.id]
        check_disposer(ask, sender, disposition)
        if ask["disposition"] in CLOSED and allow_stale:
            stale.append(disposition.id)
            continue
        require(
            ask["disposition"] in ("", "deferred"),
            f"ask already closed: {disposition.id}",
        )
    return stale


def check_disposer(ask: dict, sender: str, disposition: Disposition) -> None:
    if disposition.kind == "withdrawn":
        require(
            ask["asked_by"] == sender, f"only the asker may withdraw: {disposition.id}"
        )
    else:
        require(
            ask["asked_by"] != sender, f"cannot dispose your own ask: {disposition.id}"
        )
    require(
        disposition.kind == "answered" or disposition.reason,
        f"{disposition.kind} requires a reason: {disposition.id}",
    )


# ---------------------------------------------------------------- messages --


def prepare_message(
    store: Store,
    *,
    sender: str,
    lines: list[str],
    key: str,
    budgets: Budgets | None,
    width: int,
    now=None,
) -> dict:
    require(sender in ROLES, f"unknown sender: {sender}")
    require(str(key).strip(), "idempotency key is empty")
    moment = now or now_utc()
    with store.mutate() as state:
        require(state["phase"] == "active", "topic is finalized; use a fresh slug")
        signature = body_signature(lines, budgets)
        replay = replayed_message(state, sender, key, signature)
        if replay:
            return replay
        if budgets:
            require(
                state["participants"][peer_of(sender)],
                "bind the recipient before a blocking ask",
            )
        plan = planned(state, sender, lines, moment, width)
        message = new_message(state, sender, key, signature, plan, budgets, moment, width)
        return message_summary(message, replayed=False)


def body_signature(lines: list[str], budgets: Budgets | None) -> str:
    payload = {"lines": list(lines), "budgets": budgets.to_json() if budgets else None}
    return sha256_bytes(
        json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()
    )


def replayed_message(state: dict, sender: str, key: str, signature: str) -> dict | None:
    mid = state["keys"].get(f"{sender}:{key}")
    if mid is None:
        return None
    message = state["messages"][mid]
    require(
        message["body_sha256"] == signature,
        "idempotency key reused with different content",
    )
    return message_summary(message, replayed=True)


def planned(
    state: dict, sender: str, lines: list[str], moment: datetime, width: int
) -> Plan:
    try:
        plan = plan_body(lines, sender, StateLedger(state, sender), moment, width=width)
    except LedgerRefusal as refusal:
        raise StateError(str(refusal)) from None
    validate_dispositions(state, sender, plan.dispositions)
    return plan


def new_message(
    state, sender, key, signature, plan: Plan, budgets: Budgets | None, moment, width: int
) -> dict:
    note = budget_note(budgets) if budgets else None
    text = with_budget_line(plan.text, note, width)
    state["counters"][sender] += len(plan.new_asks)
    mid = uuid.uuid4().hex
    message = {
        "message_id": mid,
        "run_id": state["run_id"],
        "sender": sender,
        "recipient": peer_of(sender),
        "key": key,
        "body_sha256": signature,
        "text": text,
        "new_asks": [list(a) for a in plan.new_asks],
        "dispositions": [vars(d) for d in plan.dispositions],
        "warnings": plan.warnings,
        "budgets": budgets.to_json() if budgets else None,
        "budget_note": note,
        "state": "prepared",
        "claim": None,
        "events": [],
        "asks_active": False,
        "dispositions_applied": False,
        "created_at": stamp(moment),
        "submitted_at": None,
    }
    state["messages"][mid] = message
    state["keys"][f"{sender}:{key}"] = mid
    if plan.new_asks or not any(
        line.startswith("🏁") for line in plan.text.splitlines()
    ):
        state["confirmations"] = {}
    return message


def with_budget_line(text: str, note: str | None, width: int) -> str:
    if not note:
        return text
    return text + "\n\n" + "\n".join(wrap_lines([f"{BUDGET_GLYPH} {note}"], width))


def message_summary(message: dict, *, replayed: bool) -> dict:
    return {
        "message_id": message["message_id"],
        "ask_ids": [row[0] for row in message["new_asks"]],
        "text": message["text"],
        "warnings": message["warnings"],
        "replayed": replayed,
        "state": message["state"],
        "budget_note": message["budget_note"],
    }


def claim_delivery(store: Store, message_id: str, now=None) -> bool:
    with store.mutate() as state:
        return claim_in(state, message(state, message_id), now or now_utc())


def message(state: dict, message_id: str) -> dict:
    require(message_id in state["messages"], f"unknown message ID: {message_id}")
    return state["messages"][message_id]


def claim_in(state: dict, record: dict, moment: datetime, recheck: bool = True) -> bool:
    if record["claim"] is not None:
        return False
    require(
        record["state"] == "prepared",
        f"message is {record['state']}; never resend blindly",
    )
    recipient = state["participants"][record["recipient"]]
    require(recipient, "bind the actual recipient ID before dispatching")
    if recheck:
        recheck_dispositions(state, record)
    record["claim"] = {"at": stamp(moment)}
    record["recipient_binding"] = {"agent_id": recipient["agent_id"], "generation": recipient["generation"]}
    activate_asks(state, record, moment)
    return True


def recheck_dispositions(state: dict, record: dict) -> None:
    sender = record["sender"]
    plan = Plan(
        record["text"],
        [tuple(row) for row in record["new_asks"]],
        message_dispositions(record),
    )
    note_stale(record, validate_dispositions(state, sender, plan.dispositions, allow_stale=True))
    try:
        refuse_missing_dispositions(
            StateLedger(state, sender, record["message_id"]), sender, plan
        )
    except LedgerRefusal as refusal:
        raise StateError(str(refusal)) from None


def activate_asks(state: dict, record: dict, moment: datetime) -> None:
    if record["asks_active"]:
        return
    blocking = record["budgets"] is not None
    state["asks"] += [
        {
            "id": ask_id,
            "asked_by": record["sender"],
            "sent_at": stamp(moment),
            "disposition": "",
            "deferred_due": "",
            "reason": "",
            "question": question,
            "blocking": blocking,
            "message_id": record["message_id"],
            "timed_out": None,
        }
        for ask_id, question in record["new_asks"]
    ]
    record["asks_active"] = True


def observe(
    store: Store,
    message_id: str,
    event: str,
    *,
    evidence: Path | None = None,
    actor: str | None = None,
    now=None,
) -> dict:
    with store.mutate() as state:
        return observe_in(
            state,
            message(state, message_id),
            event,
            evidence_record(state, evidence, store.path.parent),
            actor,
            now or now_utc(),
        )


def evidence_record(state: dict, value: Path | str | None, topic: Path) -> dict | None:
    """`path` names a write-once copy of the bytes, so a later send or rerun that rewrites `source` cannot void the proof."""
    if value is None:
        return None
    repo = Path(state["repo"]).resolve()
    source, data = read_evidence(repo, value)
    return stored_evidence(repo, topic, source, data)


def read_evidence(repo: Path, value: Path | str) -> tuple[Path, bytes]:
    path = Path(value)
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    require(path.is_relative_to(repo), f"evidence must be inside the project: {path}")
    require(path.is_file(), f"evidence is not a file: {path}")
    data = path.read_bytes()
    require(data, f"evidence file is empty: {path}")
    return path, data


def stored_evidence(repo: Path, topic: Path, source: Path, data: bytes) -> dict:
    digest = sha256_bytes(data)
    directory = Path(topic).resolve() / EVIDENCE_DIR
    require(directory.is_relative_to(repo.resolve()), f"the evidence store must be inside the project: {directory}")
    blob = directory / digest
    require_hidden_from_git(repo.resolve(), blob)
    if not directory.exists() and not directory.is_symlink():
        directory.mkdir(mode=0o700)
    require(directory.is_dir() and not directory.is_symlink(), f"the evidence store is not a plain directory: {directory}")
    if not os.path.lexists(blob):
        publish_blob(directory, blob, data)
    require(
        blob.is_file() and not blob.is_symlink() and sha256_bytes(blob.read_bytes()) == digest,
        f"the evidence store holds different bytes for {digest}: {blob}",
    )
    return {"path": str(blob), "source": str(source), "sha256": digest}


def require_hidden_from_git(repo: Path, path: Path) -> None:
    """A proof copy must never become a visible change in the worktree it proves; outside Git there is nothing to hide from."""
    relative = str(path.relative_to(repo))
    ignored = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", "--", relative], capture_output=True)
    if ignored.returncode == 128:
        return
    tracked = subprocess.run(["git", "-C", str(repo), "ls-files", "--", relative], capture_output=True, text=True)
    require(
        ignored.returncode == 0 and tracked.returncode == 0 and not tracked.stdout,
        f"the evidence store must be Git-ignored and untracked: {relative}; ignore the whole topic directory, not only state.json",
    )


def publish_blob(directory: Path, blob: Path, data: bytes) -> None:
    """Fully written before it appears, and never replaces a blob a concurrent writer published first."""
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".incoming-")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o400)
        try:
            os.link(temporary, blob)
        except FileExistsError:
            pass
    finally:
        os.unlink(temporary)


def proof_of(event: dict) -> dict | None:
    """An event's evidence, or its latest exact-byte relocation once the original file was lost."""
    moves = event.get("relocations") or []
    return moves[-1]["evidence"] if moves else event.get("evidence")


def evidence_intact(repo: Path, proof: dict | None) -> bool:
    if not proof:
        return False
    path = Path(proof["path"]).resolve()
    return path.is_relative_to(repo.resolve()) and path.is_file() and sha256_bytes(path.read_bytes()) == proof["sha256"]


def relocate(
    store: Store, message_id: str, event_index: int, *, actor: str, evidence: Path, reason: str, now=None
) -> dict:
    """Points a lost peer receipt at a stored copy of the very same bytes.

    The original path and hash stay in the event. A file with any other digest is refused:
    a new file plus a reason could otherwise stand in for any proof nobody can check anymore.
    """
    require(str(reason).strip(), "a relocation needs a reason")
    with store.mutate() as state:
        require(state["phase"] == "active", "topic is finalized")
        record = message(state, message_id)
        require(0 <= event_index < len(record["events"]), f"message {message_id} has no event {event_index}")
        event = record["events"][event_index]
        require(event["event"] in PEER_EVENTS and event.get("evidence"), "only a peer receipt with evidence can be relocated")
        recipient = state["participants"][record["recipient"]] or {}
        require(
            actor == event["actor"] == recipient.get("agent_id"),
            "only the bound recipient who recorded the receipt may relocate it",
        )
        repo = Path(state["repo"]).resolve()
        require(not evidence_intact(repo, proof_of(event)), "the recorded evidence is intact; nothing to relocate")
        source, data = read_evidence(repo, evidence)
        require(
            sha256_bytes(data) == event["evidence"]["sha256"],
            "a relocation needs the exact original bytes; a different file cannot replace a lost proof",
        )
        entry = {
            "at": stamp(now or now_utc()),
            "actor": actor,
            "reason": reason.strip(),
            "evidence": stored_evidence(repo, store.path.parent, source, data),
        }
        event.setdefault("relocations", []).append(entry)
        return {"message_id": message_id, "event_index": event_index, **entry}


def observe_in(
    state: dict,
    record: dict,
    event: str,
    proof: dict | None,
    actor: str | None,
    moment: datetime,
) -> dict:
    require(
        proof or event not in PEER_EVENTS,
        f"{event} needs peer evidence, never a keystroke receipt",
    )
    require_actor(state, record, event, actor)
    replay = replayed_event(record, event, actor, proof)
    if replay:
        return replay
    late = event in SUBMIT_EVENTS and record["state"] in PEER_EVENTS
    allowed = TRANSITIONS[state["transport"]].get(record["state"], set())
    require(
        late or event in allowed,
        f"invalid transition {record['state']} -> {event}; never resend blindly",
    )
    hand_back = record["state"] == "prepared" and event in PEER_EVENTS
    apply_event(state, record, event, moment)
    if not late:
        record["state"] = event
    entry = {"event": event, "at": stamp(moment), "actor": actor, "evidence": proof}
    record["events"].append({**entry, "via": "hand-back"} if hand_back else entry)
    return {**record, "replayed": False}


def require_actor(state: dict, record: dict, event: str, actor: str | None) -> None:
    """Peer events come from the bound recipient; any other event, when an actor is named, from the sender."""
    role = record["recipient"] if event in PEER_EVENTS else record["sender"]
    if actor is None:
        require(event not in PEER_EVENTS, f"{event} needs the {role} peer's actor id")
        return
    bound = state["participants"][role]
    require(bound and bound["agent_id"] == actor, f"receipt actor is not the {role} peer")


def replayed_event(
    record: dict, event: str, actor: str | None, proof: dict | None
) -> dict | None:
    same = [e for e in record["events"] if e["event"] == event]
    if not same:
        return None
    require(
        any(e["actor"] == actor and same_bytes(e["evidence"], proof) for e in same),
        "same-state receipt differs from the recorded one",
    )
    return {**record, "replayed": True}


def same_bytes(recorded: dict | None, offered: dict | None) -> bool:
    """A replay matches on the evidence digest; records from before the store held only a live path."""
    return (recorded or {}).get("sha256") == (offered or {}).get("sha256")


def apply_event(state: dict, record: dict, event: str, moment: datetime) -> None:
    hand_back = record["state"] == "prepared" and event in PEER_EVENTS
    if event in CLAIM_EVENTS or hand_back:
        claim_in(state, record, moment, recheck=not hand_back)
    if event == "pasted":
        require(record["claim"] is not None, "claim_delivery before the paste")
    if event in SUBMIT_EVENTS + PEER_EVENTS:
        apply_dispositions(state, record, moment)
    if event in SUBMIT_EVENTS and record["submitted_at"] is None:
        record["submitted_at"] = stamp(moment)
        arm_timers(state, record, moment)
    if event == "failed":
        drop_undelivered_asks(state, record)


def apply_dispositions(state: dict, record: dict, moment: datetime) -> None:
    if record["dispositions_applied"]:
        return
    stale = validate_dispositions(
        state, record["sender"], message_dispositions(record), allow_stale=True
    )
    by_id = {d.id: d for d in message_dispositions(record) if d.id not in stale}
    late = [d.id for d in by_id.values() if after_stop(state, d)]
    due = stamp(moment + timedelta(minutes=DEFER_MINUTES))
    for ask in state["asks"]:
        if ask["id"] in by_id and ask["id"] not in late:
            dispose(state, ask, by_id[ask["id"]], due)
    note_stale(record, stale)
    record["late_dispositions"] = late
    record["dispositions_applied"] = True


def after_stop(state: dict, disposition: Disposition) -> bool:
    """A peer's reply to an ask whose peer was stopped is kept as history; only the asker's withdrawal closes it."""
    timer = state["timers"].get(disposition.id) or {}
    return disposition.kind != "withdrawn" and timer.get("phase") in ("stopped", "released")


def note_stale(record: dict, stale: list[str]) -> None:
    record["stale_dispositions"] = list(dict.fromkeys(record.get("stale_dispositions", []) + stale))


def dispose(state: dict, ask: dict, disposition: Disposition, due: str) -> None:
    ask["disposition"] = disposition.kind
    ask["reason"] = disposition.reason
    ask["deferred_due"] = due if disposition.kind == "deferred" else ""
    if disposition.kind in CLOSED:
        clear_timer(state, ask["id"])


def drop_undelivered_asks(state: dict, record: dict) -> None:
    require(
        not record["dispositions_applied"],
        "already submitted; not-delivered contradicts a prior receipt",
    )
    own = {row[0] for row in record["new_asks"]}
    touched = [ask for ask in state["asks"] if ask["id"] in own and ask["disposition"]]
    require(
        not touched,
        "ask already observed; cannot classify the message as not delivered",
    )
    state["asks"] = [ask for ask in state["asks"] if ask["id"] not in own]


# ------------------------------------------------------------------ timers --


def arm_timers(state: dict, record: dict, moment: datetime) -> None:
    if record["budgets"] is None:
        return
    budgets = Budgets.from_json(record["budgets"])
    recipient = state["participants"][record["recipient"]]
    for ask in open_asks_of(state, record):
        if ask["id"] not in state["timers"]:
            state["timers"][ask["id"]] = new_timer(
                state, recipient, budgets, moment, timer_gen=1
            )


def open_asks_of(state: dict, record: dict) -> list[dict]:
    own = {row[0] for row in record["new_asks"]}
    return [
        ask
        for ask in state["asks"]
        if ask["id"] in own and ask["disposition"] not in CLOSED
    ]


def new_timer(
    state: dict, recipient: dict, budgets: Budgets, moment: datetime, timer_gen: int
) -> dict:
    return {
        "run_id": state["run_id"],
        "agent_id": recipient["agent_id"],
        "generation": recipient["generation"],
        "timer_gen": timer_gen,
        "budgets": budgets.to_json(),
        "armed_at": stamp(moment),
        "expires_at": stamp(moment + timedelta(seconds=budgets.deadline.seconds)),
        "nudge_submitted_at": None,
        "grace_expires_at": None,
        "phase": "armed",
        "intent": None,
        "history": [],
    }


def rearm(store: Store, ask_id: str, budgets: Budgets, now=None) -> dict:
    """A changed deadline is a new timer_gen from now; never a silent stretch of the old one."""
    moment = now or now_utc()
    with store.mutate() as state:
        timer = live_timer(state, ask_id)
        require(
            timer["phase"] == "armed" and timer["intent"] is None,
            "only an armed timer with no intent re-arms",
        )
        recipient = state["participants"][peer_of(ask(state, ask_id)["asked_by"])]
        state["timers"][ask_id] = new_timer(
            state, recipient, budgets, moment, timer["timer_gen"] + 1
        )
        return dict(state["timers"][ask_id])


def clear_timer(state: dict, ask_id: str) -> None:
    timer = state["timers"].get(ask_id)
    if timer and timer["phase"] in ("armed", "nudged"):
        timer["phase"] = "cleared"


def token_of(ask_id: str, timer: dict) -> dict:
    return {
        "run_id": timer["run_id"],
        "ask_id": ask_id,
        "agent_id": timer["agent_id"],
        "generation": timer["generation"],
        "timer_gen": timer["timer_gen"],
    }


def due(store: Store, now=None) -> list[dict]:
    moment = stamp(now or now_utc())
    state = store.read()
    return [
        {
            "ask_id": ask_id,
            "token": token_of(ask_id, timer),
            "action": TIMER_ACTIONS[timer["phase"]],
        }
        for ask_id, timer in state["timers"].items()
        if timer["intent"] is None
        and timer_expiry(timer)
        and timer_expiry(timer) <= moment
    ]


def timer_expiry(timer: dict) -> str | None:
    if timer["phase"] == "armed":
        return timer["expires_at"]
    if timer["phase"] == "nudged":
        return timer["grace_expires_at"]
    return None


def next_wake(store: Store, wake_seconds: float, now=None) -> str:
    """The next agterm wake: one wake period away, never later than the earliest pending expiry."""
    moment = now or now_utc()
    pending = [
        timer_expiry(t) for t in store.read()["timers"].values() if t["intent"] is None
    ]
    candidates = [stamp(moment + timedelta(seconds=wake_seconds))] + [
        p for p in pending if p
    ]
    return min(candidates)


def begin(store: Store, token: Mapping[str, Any], action: str, now=None) -> dict | None:
    moment = now or now_utc()
    with store.mutate() as state:
        timer = current_timer(state, token)
        if timer is None or not claimable(state, timer, token, action, stamp(moment)):
            return None
        timer["intent"] = {
            "action": action,
            "at": stamp(moment),
            "outcome": None,
            "detail": "",
            "finished_at": None,
        }
        mark_timed_out(
            state, token["ask_id"], "nudged" if action == "nudge" else "stopped", moment
        )
        return {**timer["intent"], "token": dict(token)}


def claimable(state: dict, timer: dict, token: Mapping[str, Any], action: str, moment: str) -> bool:
    """Due now, no intent yet, the ask still open, and the token naming the run and recipient bound today."""
    expiry = timer_expiry(timer)
    row = ask(state, token["ask_id"])
    recipient = state["participants"][peer_of(row["asked_by"])] or {}
    return (TIMER_ACTIONS.get(timer["phase"]) == action and timer["intent"] is None
            and expiry is not None and expiry <= moment and row["disposition"] not in CLOSED
            and token["run_id"] == state["run_id"] and token["agent_id"] == recipient.get("agent_id")
            and token["generation"] == recipient.get("generation"))


def current_timer(state: dict, token: Mapping[str, Any]) -> dict | None:
    timer = state["timers"].get(token.get("ask_id"))
    if timer is None or token_of(token["ask_id"], timer) != dict(token):
        return None
    return timer


def ask(state: dict, ask_id: str) -> dict:
    found = [row for row in state["asks"] if row["id"] == ask_id]
    require(found, f"unknown ask: {ask_id}")
    return found[0]


def live_timer(state: dict, ask_id: str) -> dict:
    require(ask_id in state["timers"], f"no timer for ask {ask_id}")
    return state["timers"][ask_id]


def mark_timed_out(state: dict, ask_id: str, phase: str, moment: datetime) -> None:
    row = ask(state, ask_id)
    row["timed_out"] = {
        "at": (row["timed_out"] or {}).get("at", stamp(moment)),
        "phase": phase,
    }


def finish(
    store: Store,
    token: Mapping[str, Any],
    action: str,
    outcome: str,
    detail: str = "",
    now=None,
) -> dict | None:
    require(outcome in ("ok", "failed"), f"outcome must be ok or failed, got {outcome}")
    moment = now or now_utc()
    with store.mutate() as state:
        timer = current_timer(state, token)
        if timer is None or not timer["intent"] or timer["intent"]["action"] != action:
            return None
        require(
            timer["intent"]["outcome"] is None,
            "intent already has an outcome; never repeated",
        )
        timer["intent"].update(
            outcome=outcome, detail=detail, finished_at=stamp(moment)
        )
        if outcome == "ok":
            complete_action(timer, action, moment)
        return dict(timer)


def complete_action(timer: dict, action: str, moment: datetime) -> None:
    """A nudge finishing after the answer cleared the timer stays history; a stop still reserves the scope."""
    if action == "nudge" and timer["phase"] == "cleared":
        timer["history"].append(timer["intent"])
        timer["intent"] = None
        return
    if action == "nudge":
        grace = Budgets.from_json(timer["budgets"]).grace.seconds
        timer["nudge_submitted_at"] = stamp(moment)
        timer["grace_expires_at"] = stamp(moment + timedelta(seconds=grace))
    timer["phase"] = "nudged" if action == "nudge" else "stopped"
    timer["history"].append(timer["intent"])
    timer["intent"] = None


def nudge_submitted(store: Store, token: Mapping[str, Any], now=None) -> str:
    finished = finish(store, token, "nudge", "ok", "nudge submitted", now=now)
    require(finished, "no open nudge intent for this token; begin the nudge first")
    return finished["grace_expires_at"]


def withdraw(store: Store, ask_id: str, *, actor: str, reason: str, evidence: Path, now=None) -> dict:
    """The asker closes its own open ask locally, so a stopped peer is never messaged; a stopped scope still needs release."""
    require(str(reason).strip(), "a withdrawal needs a reason")
    moment = now or now_utc()
    with store.mutate() as state:
        row = ask(state, ask_id)
        require(row["disposition"] in ("", "deferred"), f"ask already closed: {ask_id}")
        asker = state["participants"][row["asked_by"]] or {}
        require(actor == asker.get("agent_id"), f"only the asker ({row['asked_by']}) may withdraw {ask_id}")
        proof = evidence_record(state, evidence, store.path.parent)
        require(proof, "a withdrawal needs an evidence file")
        dispose(state, row, Disposition(ask_id, "withdrawn", reason.strip()), "")
        row["withdrawal"] = {"at": stamp(moment), "actor": actor, "evidence": proof}
        return dict(row)


def release(store: Store, ask_id: str, evidence: Path, now=None) -> dict:
    moment = now or now_utc()
    with store.mutate() as state:
        timer = live_timer(state, ask_id)
        require(
            timer["phase"] == "stopped",
            f"timer is {timer['phase']}; only a stopped peer is released",
        )
        timer["release"] = {
            "at": stamp(moment),
            "evidence": evidence_record(state, evidence, store.path.parent),
        }
        timer["phase"] = "released"
        return dict(timer)


# ----------------------------------------------------------------- freezes --


def record_freeze(
    store: Store, repo_root: Path, tree: str, pathspecs: list[str], now=None
) -> dict:
    repo = str(Path(repo_root).resolve())
    with store.mutate() as state:
        previous = previous_tree(state, repo)
        row = {
            "n": len(state["freezes"]) + 1,
            "repo": repo,
            "tree": tree,
            "previous": previous,
            "pathspecs": list(pathspecs),
            "at": stamp(now or now_utc()),
            "legacy": False,
        }
        state["freezes"].append(row)
        return dict(row)


def previous_tree(state: dict, repo: str) -> str:
    own = [row["tree"] for row in state["freezes"] if row["repo"] == repo]
    return own[-1] if own else head_or_empty(Path(repo))


def head_or_empty(repo: Path) -> str:
    """A repo's first freeze diffs against its HEAD, or the empty tree when HEAD is unborn."""
    probe = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "-q", "HEAD"],
                           capture_output=True, text=True, check=False)
    return probe.stdout.strip() or EMPTY_TREE


# ------------------------------------------------------------------ status --


def unresolved_timers(state: dict) -> list[dict]:
    """Intents without a closing outcome, failed actions and stopped peers whose scope is still reserved."""
    return [
        {"ask_id": ask_id, "phase": timer["phase"], "intent": timer["intent"]}
        for ask_id, timer in state["timers"].items()
        if timer["intent"] or timer["phase"] == "stopped"
    ]


def status(store: Store) -> dict:
    state = store.read()
    return {
        **state,
        "state_file": str(store.path),
        "open_asks": [a["id"] for a in state["asks"] if a["disposition"] not in CLOSED],
        "unresolved_messages": [
            mid
            for mid, m in state["messages"].items()
            if m["state"] not in TERMINAL_MESSAGES
        ],
        "unresolved_intents": [
            {"ask_id": ask_id, **t["intent"]}
            for ask_id, t in state["timers"].items()
            if t["intent"]
        ],
    }
