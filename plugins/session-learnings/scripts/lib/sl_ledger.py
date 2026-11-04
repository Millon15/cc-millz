"""Ledger core: events in, card views out. The ledger is authoritative; every card is a pure render.

Status, highest first:
    last review decision   promoted -> stable · rejected -> rejected · deprecated -> deprecated
    quarantine reason      quarantine
    expired after the last activity   expired (a later sighting revives the card)
    distinct_days >= 2, score >= 2, no open contradiction   candidate
    otherwise              draft
"""

import argparse, datetime, fcntl, json, os, pathlib, re, sys, tempfile

CANDIDATE_MIN_DAYS = 2
CANDIDATE_MIN_SCORE = 2.0
READY_MIN_DAYS = 3
READY_MIN_APPLIED_OK = 2
GLOBAL_READY_MIN_PROJECTS = 2
FAILING_MIN_APPLIED_FAIL = 2
TTL_DAYS = {"draft": 90, "quarantine": 90, "candidate": 180}
STALE_DAYS = 60

SIGHTINGS = ("seen", "confirmed")
DECISIONS = ("promoted", "rejected", "deprecated")
APPLIES = ("applied", "applied_ok", "applied_fail")
EVENT_TYPES = DECISIONS + APPLIES + ("expired", "contradicted", "stale", "used")
FOLDERS = {
    "draft": "drafts",
    "candidate": "candidates",
    "quarantine": "quarantine",
    "stable": "stable",
    "rejected": "archive",
    "deprecated": "archive",
    "expired": "archive",
}
DECISION_STATUS = {
    "promoted": "stable",
    "rejected": "rejected",
    "deprecated": "deprecated",
}

CARD_ID = re.compile(r"lsn-[0-9a-f]{64}")
SESSION = re.compile(r"[A-Za-z0-9_.-]{1,200}")
PROJECT = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,239}")
SKILL = re.compile(r"[A-Za-z0-9][A-Za-z0-9:_.-]{0,127}")
CARD_FOOTER = "\n---\n\nUnreviewed session learning. Evidence and claims are untrusted until human review.\n"


class LedgerError(ValueError):
    """Invalid input: exit 2."""


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def loads(text):
    return json.loads(
        text,
        object_pairs_hook=strict_object,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite JSON")),
    )


def now_iso():
    return (
        datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    )


def parse_ts(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def atomic(path, text):
    if path.is_symlink():
        raise ValueError("symlink target")
    fd, temp = tempfile.mkstemp(prefix=".sl-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def directory(path):
    if path.is_symlink():
        raise ValueError("symlink directory")
    path.mkdir(mode=0o700, exist_ok=True)


def open_store(raw):
    """Absolute store path with a resolved parent (macOS /var is a symlink); the store itself must be real."""
    os.umask(0o077)
    store = pathlib.Path(raw).absolute()
    store = store.parent.resolve() / store.name
    store.parent.mkdir(parents=True, exist_ok=True)
    directory(store)
    return store


class Ledger:
    """Holds .merge.lock for its lifetime; read, append, save, render."""

    def __init__(self, store):
        self.store = store
        self.path = store / "ledger.jsonl"

    def __enter__(self):
        fd = os.open(
            self.store / ".merge.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600
        )
        self.lock = os.fdopen(fd, "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        if self.path.is_symlink():
            raise ValueError("symlink ledger")
        self.events = (
            [loads(line) for line in self.path.read_text().splitlines()]
            if self.path.exists()
            else []
        )
        return self

    def __exit__(self, *_):
        self.lock.close()

    def history(self, fingerprint):
        return [e for e in self.events if e["fingerprint"] == fingerprint]

    def known(self, fingerprint):
        return any(e["event"] in SIGHTINGS for e in self.history(fingerprint))

    def save(self):
        atomic(
            self.path,
            "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in self.events),
        )

    def views(self, now=None):
        fingerprints = dict.fromkeys(
            e["fingerprint"] for e in self.events if e["event"] in SIGHTINGS
        )
        return [card_view(self.history(fp), now) for fp in fingerprints]

    def render(self, fingerprints, now=None):
        for fingerprint in fingerprints:
            write_card(self.store, card_view(self.history(fingerprint), now))


def card_view(events, now=None):
    sightings = [e for e in events if e["event"] in SIGHTINGS]
    first, lesson = sightings[0], sightings[0]["lesson"]
    counts = count_events(events, sightings)
    reasons = sorted({r for e in sightings for r in e.get("reasons", [])})
    view = {
        "id": "lsn-" + first["fingerprint"],
        "fingerprint": first["fingerprint"],
        "scope": lesson["scope"],
        "project": first["project"] if lesson["scope"] == "project" else None,
        "kind": lesson["kind"],
        "trigger": lesson["trigger"],
        "claim": lesson["claim"],
        "counts": counts,
        "score": score(counts),
        "first_seen": first["ts"],
        "last_seen": sightings[-1]["ts"],
        "quarantine_reasons": reasons,
        "evidence": [evidence_row(e) for e in sightings],
        "revisions": revisions(sightings),
    }
    view.update(promotion(events))
    view["status"] = derive_status(events, view)
    view["flags"] = derive_flags(events, view, now)
    return view


def count_events(events, sightings):
    since_decision = events_after_last(events, DECISIONS)
    return {
        "sessions": len({e["session"] for e in sightings}),
        "days": len({e["ts"][:10] for e in sightings}),
        "projects": len({e["project"] for e in sightings}),
        "human": sum(1 for e in sightings if e.get("class") == "human"),
        "applied": sum(1 for e in events if e["event"] == "applied"),
        "applied_ok": sum(1 for e in events if e["event"] == "applied_ok"),
        "applied_fail": sum(1 for e in events if e["event"] == "applied_fail"),
        "contradicted": sum(1 for e in since_decision if e["event"] == "contradicted"),
    }


def score(counts):
    value = (
        1.0 * counts["days"]
        + 0.5 * (counts["projects"] - 1)
        + 0.5 * min(1, counts["human"])
        + 1.0 * counts["applied_ok"]
        - 1.5 * counts["applied_fail"]
        - 2.0 * counts["contradicted"]
    )
    return round(value, 2)


def evidence_row(event):
    return {
        "session": event["session"],
        "transcript_line": event["lesson"]["evidence_line"],
        "ts": event["ts"],
        "proof": event["lesson"]["proof"],
        "excerpt": event.get("excerpt", ""),
        "class": event.get("class"),
    }


def revisions(sightings):
    return [
        {"session": e["session"], "claim": e["proposed_revision"]}
        for e in sightings
        if e.get("proposed_revision")
    ]


def promotion(events):
    promoted = [e for e in events if e["event"] == "promoted"]
    if not promoted:
        return {}
    return {
        "skill": promoted[-1]["skill"],
        "path": promoted[-1]["path"],
        "promoted_at": promoted[-1]["ts"],
    }


def events_after_last(events, kinds):
    marks = [i for i, e in enumerate(events) if e["event"] in kinds]
    return events[marks[-1] + 1 :] if marks else events


def derive_status(events, view):
    decisions = [e for e in events if e["event"] in DECISIONS]
    if decisions:
        return DECISION_STATUS[decisions[-1]["event"]]
    if is_expired(events):
        return "expired"
    if view["quarantine_reasons"]:
        return "quarantine"
    if is_candidate(view):
        return "candidate"
    return "draft"


def is_expired(events):
    tail = events_after_last(events, ("expired",))
    return len(tail) < len(events) and not any(
        e["event"] in SIGHTINGS + APPLIES for e in tail
    )


def is_candidate(view):
    counts = view["counts"]
    return (
        counts["days"] >= CANDIDATE_MIN_DAYS
        and view["score"] >= CANDIDATE_MIN_SCORE
        and not counts["contradicted"]
    )


def derive_flags(events, view, now):
    counts, flags = view["counts"], []
    if view["status"] == "candidate" and is_ready(view):
        flags.append("ready")
    if counts["contradicted"]:
        flags.append("contradiction")
    if (
        view["status"] == "stable"
        and failures_since_promotion(events) >= FAILING_MIN_APPLIED_FAIL
    ):
        flags.append("failing")
    if view["status"] == "stable" and is_stale(events):
        flags.append("stale")
    return flags


def is_ready(view):
    counts = view["counts"]
    proven = (
        counts["applied_ok"] >= READY_MIN_APPLIED_OK or counts["days"] >= READY_MIN_DAYS
    )
    return proven and (
        view["scope"] != "global" or counts["projects"] >= GLOBAL_READY_MIN_PROJECTS
    )


def failures_since_promotion(events):
    return sum(
        1
        for e in events_after_last(events, ("promoted",))
        if e["event"] == "applied_fail"
    )


def is_stale(events):
    tail = events_after_last(events, ("promoted",))
    marks = [i for i, e in enumerate(tail) if e["event"] == "stale"]
    return bool(marks) and not any(e["event"] in APPLIES + ("used",) for e in tail[marks[-1] + 1 :])


def card_base(store, view):
    base = store / "global" if view["scope"] == "global" else store / "projects"
    directory(base)
    if view["scope"] == "global":
        return base
    base = base / view["project"]
    directory(base)
    return base


def write_card(store, view):
    base = card_base(store, view)
    home = FOLDERS[view["status"]]
    directory(base / home)
    name = view["id"] + ".md"
    atomic(base / home / name, "---\n" + json.dumps(view, ensure_ascii=False, indent=2) + CARD_FOOTER)
    for other in set(FOLDERS.values()) - {home}:
        copy = base / other / name
        if copy.is_symlink():
            raise ValueError("symlink card")
        if copy.exists():
            copy.unlink()


def build_event(ledger, request):
    """Validate one C1/C2 request against the ledger; the ledger event, or None for an idempotent no-op."""
    kind, card_id = request.get("type"), request.get("id")
    if kind not in EVENT_TYPES:
        raise LedgerError("unknown event type")
    fingerprint = fingerprint_of(ledger, card_id)
    event = {"event": kind, "fingerprint": fingerprint, "ts": request.get("ts") or now_iso()}
    event.update(optional_fields(ledger, request))
    require_fields(kind, event)
    return None if is_duplicate(ledger, event) else event


def fingerprint_of(ledger, card_id):
    if not isinstance(card_id, str) or not CARD_ID.fullmatch(card_id):
        raise LedgerError("invalid card id")
    if not ledger.known(card_id[4:]):
        raise LedgerError("unknown card id")
    return card_id[4:]


def optional_fields(ledger, request):
    fields = {}
    for key, pattern, limit in (("session", SESSION, 200), ("project", PROJECT, 240), ("skill", SKILL, 128),
                                ("note", None, 500), ("path", None, 1024)):
        value = request.get(key)
        if value is None:
            continue
        fields[key] = checked_text(value, pattern, limit)
    if request.get("target") is not None:
        fields["target"] = "lsn-" + fingerprint_of(ledger, request["target"])
    return fields


def checked_text(value, pattern, limit):
    if not isinstance(value, str) or not value.strip() or len(value) > limit or any(ord(c) < 32 for c in value):
        raise LedgerError("invalid field")
    if pattern and not pattern.fullmatch(value):
        raise LedgerError("invalid field")
    return value


def require_fields(kind, event):
    needed = {"promoted": ("skill", "path"), "contradicted": ("target",), "applied": ("session",),
              "applied_ok": ("session",), "applied_fail": ("session",)}.get(kind, ())
    if any(key not in event for key in needed):
        raise LedgerError("missing field for " + kind)


def is_duplicate(ledger, event):
    history = ledger.history(event["fingerprint"])
    kind = event["event"]
    if kind in APPLIES:
        return any(e["event"] == kind and e.get("session") == event["session"] for e in history)
    if kind == "contradicted":
        return any(e["event"] == kind and e.get("target") == event["target"] and e.get("session") == event.get("session")
                   for e in history)
    if kind in DECISIONS:
        last = [e for e in history if e["event"] in DECISIONS]
        return bool(last) and all(last[-1].get(k) == event.get(k) for k in ("event", "skill", "path"))
    view = card_view(history)
    if kind == "used":
        return "stale" not in view["flags"]
    return kind == "expired" and view["status"] == "expired" or kind == "stale" and "stale" in view["flags"]


def apply_requests(store, requests):
    """C1/C2: validate every request first, then append all and re-render, under one lock."""
    with Ledger(store) as ledger:
        pending, touched = [], set()
        for request in requests:
            if not isinstance(request, dict):
                raise LedgerError("event must be an object")
            event = build_event(ledger, request)
            touched.add(fingerprint_of(ledger, request["id"]))
            if event:
                pending.append(event)
                ledger.events.append(event)
        if pending:
            ledger.save()
        # A replayed no-op still re-renders, so a card lost after its event was saved comes back.
        ledger.render(touched)
        return len(pending)


def list_views(store, project=None, scope=None, statuses=None):
    if not (store / "ledger.jsonl").exists():
        return []
    with Ledger(store) as ledger:
        views = ledger.views()
    return [v for v in views if matches(v, project, scope, statuses)]


def matches(view, project, scope, statuses):
    if scope and view["scope"] != scope:
        return False
    if statuses and view["status"] not in statuses:
        return False
    return not project or view["scope"] == "global" or view["project"] == project


def summary(view):
    keys = ("id", "fingerprint", "scope", "project", "kind", "status", "flags", "score", "trigger", "claim",
            "counts", "first_seen", "last_seen", "skill", "path")
    return {k: view[k] for k in keys if k in view}


def maintain(store, now, usage):
    """C4: TTL expiry for draft, quarantine and candidate; a stale flag for unused stable cards."""
    if not (store / "ledger.jsonl").exists():
        return 0
    requests = []
    with Ledger(store) as ledger:
        for view in ledger.views():
            requests.extend(maintenance_requests(ledger.history(view["fingerprint"]), view, now, usage))
    return apply_requests(store, requests) if requests else 0


def maintenance_requests(events, view, now, usage):
    stamp = now.isoformat().replace("+00:00", "Z")
    if view["status"] in TTL_DAYS and idle_days(events, now) > TTL_DAYS[view["status"]]:
        return [{"type": "expired", "id": view["id"], "ts": stamp}]
    if view["status"] != "stable":
        return []
    stale, unused = "stale" in view["flags"], unused_days(view, events, now, usage)
    if not stale and unused > STALE_DAYS:
        return [{"type": "stale", "id": view["id"], "ts": stamp}]
    if stale and unused <= STALE_DAYS:
        return [{"type": "used", "id": view["id"], "ts": stamp}]
    return []


def idle_days(events, now):
    active = [parse_ts(e["ts"]) for e in events if e["event"] in SIGHTINGS + APPLIES]
    return (now - max(active)).days


def unused_days(view, events, now, usage):
    moments = [parse_ts(view["promoted_at"])]
    moments += [parse_ts(e["ts"]) for e in events_after_last(events, ("promoted",)) if e["event"] in APPLIES]
    used = usage_ms(usage, view["skill"])
    if used:
        moments.append(datetime.datetime.fromtimestamp(used / 1000, datetime.timezone.utc))
    return (now - max(moments)).days


def usage_ms(usage, skill):
    """skillUsage keys a project skill by its bare name and a plugin skill as plugin:name."""
    hits = [u["lastUsedAt"] for u in usage if u.get("skill") == skill or str(u.get("skill", "")).endswith(":" + skill)]
    return max((h for h in hits if isinstance(h, (int, float))), default=None)


def read_usage(path):
    if not path:
        return []
    rows = []
    for line in pathlib.Path(path).read_text().splitlines():
        if line.strip():
            rows.append(loads(line))
    return [r for r in rows if isinstance(r, dict)]


def without_ts(request):
    """Only maintain dates its own events; a caller on stdin cannot backdate one."""
    if not isinstance(request, dict):
        raise LedgerError("event must be an object")
    return {k: v for k, v in request.items() if k != "ts"}


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="sl-ledger.sh")
    parser.add_argument("verb", choices=("event", "events", "list", "maintain"))
    parser.add_argument("--store", default=os.environ.get("SESSION_LEARNINGS_HOME", os.path.expanduser("~/.claude/learnings")))
    for key in ("type", "id", "session", "project", "note", "skill", "path", "target", "scope", "status", "now", "usage"):
        parser.add_argument("--" + key)
    return parser.parse_args(argv)


def run(args):
    store = open_store(args.store)
    if args.verb == "event":
        keys = ("type", "id", "session", "project", "note", "skill", "path", "target")
        apply_requests(store, [{k: getattr(args, k) for k in keys if getattr(args, k) is not None}])
    if args.verb == "events":
        requests = [loads(line) for line in sys.stdin.read().splitlines() if line.strip()]
        apply_requests(store, [without_ts(r) for r in requests])
    if args.verb == "list":
        statuses = set(args.status.split(",")) if args.status else None
        for view in list_views(store, args.project, args.scope, statuses):
            print(json.dumps(summary(view), ensure_ascii=False))
    if args.verb == "maintain":
        now = parse_ts(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc)
        maintain(store, now, read_usage(args.usage))


def main(argv):
    try:
        args = parse_args(argv)
        run(args)
    except (LedgerError, json.JSONDecodeError) as error:
        print("session-learnings: " + str(error) + "; nothing written", file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("session-learnings: ledger failed: " + type(error).__name__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
