#!/usr/bin/env python3
"""Durable native-peer protocol on schema 2 state. Records evidence; never launches or impersonates a host tool."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace

sys.dont_write_bytecode = (
    True  # --explain must not populate the installed cache either.
)
sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import (
    ASK_ID_RE,
    LedgerRefusal,
    clean_lines,
    freeze_tree,
    is_ask,
    now_utc,
    peer_of,
    stamp,
)
import peer_chat_state as ps

ROLES = ("left", "right")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,59}\Z")
TERMINAL = set(ps.TERMINAL_MESSAGES)
RECEIPT_STATES = (
    "dispatching",
    "submitted",
    "uncertain",
    "acknowledged",
    "answered",
    "failed",
    "cancelled",
)
PROFILE_KEYS = {"state_dir", "stall_minutes", "grace_minutes"}
class Refusal(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def repo_path(value):
    path = Path(value or os.getcwd()).resolve()
    probe = subprocess.run(["git", "-C", str(path), "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True)
    return Path(probe.stdout.strip()).resolve() if probe.returncode == 0 else path


def config(repo):
    profile = repo / ".peer-chat-bg.json"
    values = {"state_dir": "tmp/peer-chat-bg"}
    sources = {"state_dir": "default"}
    if profile.exists():
        data = json.loads(profile.read_text())
        require(isinstance(data, dict), "profile must be a JSON object")
        require(not (set(data) - PROFILE_KEYS), "unknown profile keys")
        for key in sorted(data):
            values[key] = data[key]
            sources[key] = "profile"
    require((repo / ".git").exists() or profile.exists(),
            "no project markers found: .git or .peer-chat-bg.json; pass --repo")
    value = values["state_dir"]
    require(isinstance(value, str) and value and not Path(value).is_absolute()
            and ".." not in Path(value).parts and value != ".", "state_dir must be a relative project path")
    root = (repo / value).resolve()
    require(root.is_relative_to(repo) and root != repo, "state_dir escapes project")
    return {"plugin": "peer-chat-bg", "profile_file": str(profile) if profile.exists() else None,
            "values": values, "sources": sources,
            "profile": {key: values[key] for key in values if key != "state_dir"}}


def evidence(repo, value):
    require(bool(value), "this receipt requires --evidence FILE from the actual tool/peer result")
    path = Path(value)
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    require(path.is_file() and path.is_relative_to(repo), "evidence must be an existing file inside the project")
    data = path.read_bytes()
    require(bool(data), "evidence file is empty")
    return {"path": str(path), "sha256": digest(data)}


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True)
    require(result.returncode == 0, "Git operation failed: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def ignored_path(repo, path):
    relative = str(path.relative_to(repo))
    ignored = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", "--", relative]).returncode == 0
    require(ignored, "protocol artifacts must be Git-ignored: " + relative + "; add a narrow .gitignore rule first")
    require(not git(repo, "ls-files", "--", relative), "protocol artifacts must not be tracked: " + relative)


def tree_snapshot(repo):
    """Content-address the whole visible working tree, including new untracked files."""
    paths = sorted(set(git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")) - {b""})
    files = {}
    for raw in paths:
        name = os.fsdecode(raw)
        path = repo / name
        if path.is_symlink():
            files[name] = {"kind": "symlink", "sha256": digest(os.fsencode(os.readlink(path)))}
        elif not path.exists():
            files[name] = {"kind": "deleted"}
        else:
            require(path.is_file(), "cannot freeze directory/submodule as a file: " + name)
            files[name] = {"kind": "file", "sha256": digest(path.read_bytes()), "executable": bool(path.stat().st_mode & 0o111)}
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "HEAD"], capture_output=True, text=True)
    return {"schema": 1, "repo": str(repo), "head": head.stdout.strip() if head.returncode == 0 else None, "files": files}


def freeze_target(repo, value, since=None):
    path = Path(value)
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    require(path.is_relative_to(repo), "target manifest must be inside the project")
    ignored_path(repo, path)
    require(not path.exists(), "target manifest exists; freeze to a fresh file")
    before = load_manifest(repo, since)["files"] if since else None
    frozen = tree_snapshot(repo)
    data = (json.dumps(frozen, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    token = "manifest:" + str(path.relative_to(repo)) + "#" + digest(data)
    result = {"target": token, "manifest": str(path), "files": len(frozen["files"]), "tree": freeze_tree(repo)}
    if before is not None:
        result["changed"] = changed_files(before, frozen["files"])
    return result


def validate_target(repo, target):
    if target.startswith("git:"):
        expected = target[4:]
        require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", expected), "git target requires a full commit SHA")
        require(git(repo, "rev-parse", "HEAD").decode().strip() == expected, "target HEAD changed")
        require(not git(repo, "status", "--porcelain=v1", "--untracked-files=all"), "git target requires a clean tracked and untracked working tree")
        # git status can hide assume-unchanged/skip-worktree paths. Compare actual
        # bytes/modes with HEAD as well; filtered checkouts can use manifest targets.
        algorithm = git(repo, "rev-parse", "--show-object-format").decode().strip()
        for row in git(repo, "ls-tree", "-rz", "--full-tree", "HEAD").split(b"\0"):
            if not row:
                continue
            metadata, name = row.split(b"\t", 1)
            mode, kind, object_id = metadata.split()
            path = repo / os.fsdecode(name)
            require(kind == b"blob", "git targets with submodules are unsupported")
            if mode == b"120000":
                require(path.is_symlink(), "target file kind changed")
                data = os.fsencode(os.readlink(path))
            else:
                require(path.is_file() and not path.is_symlink(), "target file kind changed")
                require(bool(path.stat().st_mode & 0o111) == (mode == b"100755"), "target file mode changed")
                data = path.read_bytes()
            actual = hashlib.new(algorithm, b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            require(actual == object_id.decode(), "target file bytes changed: " + os.fsdecode(name))
        return
    require(load_manifest(repo, target) == tree_snapshot(repo), "target working tree changed; freeze a new target and re-run checks")


def load_manifest(repo, target):
    """The frozen snapshot behind a manifest token, after its path and digest check out."""
    require(target.startswith("manifest:") and "#" in target, "target must come from target command, or git:<full-sha>")
    name, expected = target[len("manifest:"):].rsplit("#", 1)
    require(re.fullmatch(r"[0-9a-f]{64}", expected), "invalid manifest SHA256")
    relative = Path(name)
    require(not relative.is_absolute() and ".." not in relative.parts, "manifest path must be project-relative")
    path = (repo / relative).resolve()
    require(path.is_relative_to(repo) and path.is_file(), "target manifest is missing or outside project")
    ignored_path(repo, path)
    data = path.read_bytes()
    require(digest(data) == expected, "target manifest changed")
    return json.loads(data)


def changed_files(before, after):
    """Files whose frozen entry differs from the earlier manifest: the reviewer reads only these."""
    return sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))


def validate_evidence(record):
    path = Path(record["path"])
    require(path.is_file() and digest(path.read_bytes()) == record["sha256"], "evidence changed or disappeared: " + str(path))

def status_of(store):
    return ps.status(store)


def init(args, repo, path):
    require(args.parent_id.strip(), "parent ID is empty")
    require(all(name.strip() for name in args.check), "check names cannot be empty")
    store = ps.open_topic(path, transport="bg", slug=args.slug, host=args.host, repo=repo,
                          on_create=lambda state: seed_topic(state, args))
    require_same_identity(store.read(), args, repo)
    return status_of(store)


def seed_topic(state, args):
    state["participants"]["left"] = ps.participant_record({"agent_id": args.parent_id, "harness": args.host})
    state["checks"] = {name: {"state": "incomplete"} for name in args.check}


def require_same_identity(state, args, repo):
    left = state["participants"]["left"] or {}
    require(
        state["repo"] == str(repo)
        and state["host"] == args.host
        and left.get("agent_id") == args.parent_id,
        "topic exists with different identity; use a fresh slug",
    )
    require(
        set(args.check) == set(state["checks"]),
        "topic exists with a different required-check set",
    )


def actor_role(state, actor):
    roles = [
        role
        for role, who in state["participants"].items()
        if who and who["agent_id"] == actor
    ]
    require(len(roles) == 1, "actor ID does not identify a bound peer in this run")
    return roles[0]


def bind(args, store, state):
    require(args.agent_id.strip(), "agent ID is empty")
    require(
        args.agent_id != state["participants"]["left"]["agent_id"],
        "peer must not be the parent",
    )
    prior = state["participants"][args.role]
    require(
        not prior or prior["agent_id"] == args.agent_id,
        "role already bound; no silent identity replacement; use a fresh slug",
    )
    bound = ps.bind_participant(
        store, args.role, {"agent_id": args.agent_id, "harness": state["host"]}
    )
    return {"run_id": state["run_id"], "role": args.role, **bound}


def prepare(args, store, state, profile):
    require(state["participants"][args.sender], "sender role is not bound")
    lines = clean_lines(SimpleNamespace(label=f"Chat from {args.sender}: "), args.body)
    require(
        not any(is_ask(line) and ASK_ID_RE.search(line) for line in lines),
        "new asks must not supply their own IDs",
    )
    for ignored in (args.wake, args.est_wake):
        if ignored:
            ps.parse_duration(ignored)
    budgets = ps.resolve_budgets(
        "bg",
        args.blocking,
        flags=budget_flags(args, ""),
        estimates=budget_flags(args, "est_"),
        env=os.environ,
        profile=profile,
    )
    prepared = ps.prepare_message(
        store, sender=args.sender, lines=lines, key=args.key, budgets=budgets, width=0
    )
    return {
        **store.read()["messages"][prepared["message_id"]],
        "replayed": prepared["replayed"],
    }


def budget_flags(args, prefix):
    return {name: getattr(args, prefix + name, None) for name in ps.BUDGET_FIELDS}


def receipt(args, store, repo):
    with store.mutate() as state:
        record = ps.message(state, args.message_id)
        role = actor_role(state, args.actor_id)
        desired = (
            record["recipient"] if args.state in ps.PEER_EVENTS else record["sender"]
        )
        require(role == desired, "receipt actor is not the " + desired + " peer")
        proof = None if args.state == "dispatching" else evidence(repo, args.evidence)
        before = record["claim"]
        result = ps.observe_in(
            state, record, args.state, proof, args.actor_id, now_utc()
        )
        return {
            **result,
            "dispatch_permitted": args.state == "dispatching" and before is None,
        }


def check(args, store, repo):
    with store.mutate() as state:
        require(args.name in state["checks"], "check was not declared by init")
        validate_target(repo, args.target)
        state["checks"][args.name] = {
            "state": args.state,
            "target": args.target,
            "evidence": evidence(repo, args.evidence),
            "at": stamp(now_utc()),
        }
        state["confirmations"] = {}
        return {"name": args.name, **state["checks"][args.name]}


def finalize(args, store, repo):
    with store.mutate() as state:
        role = actor_role(state, args.actor_id)
        validate_target(repo, args.target)
        require_closable(state, args.target)
        other = state["confirmations"].get(peer_of(role))
        require(
            not other or other["target"] == args.target,
            "peers confirmed different final targets",
        )
        state["confirmations"][role] = {
            "target": args.target,
            "actor_id": args.actor_id,
            "evidence": evidence(repo, args.evidence),
            "at": stamp(now_utc()),
        }
        if len(state["confirmations"]) == 2:
            state["phase"] = "finalized"
            state["finalized_at"] = stamp(now_utc())
        return {
            "run_id": state["run_id"],
            "phase": state["phase"],
            "confirmations": state["confirmations"],
        }


def require_closable(state, target):
    require(state["participants"]["right"], "peer is not bound")
    require(
        all(ask["disposition"] in ps.CLOSED for ask in state["asks"]),
        "open or deferred asks remain",
    )
    require(
        all(message["state"] in TERMINAL for message in state["messages"].values()),
        "unresolved message receipts remain",
    )
    require(
        all(
            check["state"] == "passed" and check["target"] == target
            for check in state["checks"].values()
        ),
        "required checks incomplete, failed or on a different target",
    )
    require(
        all(
            any(
                m["sender"] == sender and m["state"] in ps.PEER_EVENTS
                for m in state["messages"].values()
            )
            for sender in ROLES
        ),
        "no two-way peer exchange; an ACK alone is not a substantive reply",
    )
    require(
        not ps.unresolved_timers(state),
        "timer intents or stopped peers are not reconciled",
    )
    for record in list(state["checks"].values()) + list(
        state["confirmations"].values()
    ):
        validate_evidence(record["evidence"])


def token_arg(value):
    try:
        token = json.loads(value)
    except json.JSONDecodeError as error:
        raise Refusal(
            "--token must be the JSON token printed by wake: " + str(error)
        ) from None
    require(isinstance(token, dict), "--token must be a JSON object")
    return token


def timer_command(args, store, repo):
    if args.command == "wake":
        return {"due": ps.due(store), "status": "read-only"}
    if args.command == "begin":
        return {"intent": ps.begin(store, token_arg(args.token), args.action)}
    if args.command == "finish":
        return {
            "timer": ps.finish(
                store,
                token_arg(args.token),
                args.action,
                args.outcome,
                args.detail or "",
            )
        }
    if args.command == "nudged":
        return {"grace_expires_at": ps.nudge_submitted(store, token_arg(args.token))}
    if args.command == "withdraw":
        return {"ask": ps.withdraw(store, args.ask_id, actor=args.actor_id, reason=args.reason,
                                   evidence=Path(evidence(repo, args.evidence)["path"]))}
    if args.command == "release":
        return {
            "timer": ps.release(
                store, args.ask_id, Path(evidence(repo, args.evidence)["path"])
            )
        }
    raise Refusal("unknown command")


def mutate(args, store, repo, profile):
    state = store.read()
    require(
        args.run == state["run_id"], "missing or stale --run identity; inspect status"
    )
    require(state["phase"] == "active", "topic is finalized; use a fresh slug")
    if args.command == "target":
        return freeze_target(repo, args.output, args.since)
    if args.command == "bind":
        return bind(args, store, state)
    if args.command == "prepare":
        return prepare(args, store, state, profile)
    if args.command == "receipt":
        return receipt(args, store, repo)
    if args.command == "check":
        return check(args, store, repo)
    if args.command == "finalize":
        return finalize(args, store, repo)
    return timer_command(args, store, repo)


def add_budget_flags(q):
    q.add_argument(
        "--blocking",
        action="store_true",
        help="every new ask of this message arms a timer",
    )
    for name in ps.BUDGET_FIELDS:
        q.add_argument(
            "--" + name, help="the user's value: 90s, 20m or 1h (source flag); bg validates and ignores wake"
        )
        q.add_argument(
            "--est-" + name,
            dest="est_" + name,
            help="your estimate for this ask (source agent)",
        )


def add_timer_commands(sub):
    sub.add_parser(
        "wake", help="read-only: the due nudge/stop actions with their tokens"
    )
    for name in ("begin", "finish"):
        q = sub.add_parser(name)
        q.add_argument("--token", required=True)
        q.add_argument("--action", choices=("nudge", "stop"), required=True)
        if name == "finish":
            q.add_argument("--outcome", choices=("ok", "failed"), required=True)
            q.add_argument("--detail")
    sub.add_parser("nudged").add_argument("--token", required=True)
    q = sub.add_parser("release")
    q.add_argument("--ask-id", required=True)
    q.add_argument("--evidence", required=True)
    q = sub.add_parser("withdraw", help="the asker closes its own ask without messaging the peer")
    q.add_argument("--ask-id", required=True)
    q.add_argument("--actor-id", required=True)
    q.add_argument("--reason", required=True)
    q.add_argument("--evidence", required=True)


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo")
    p.add_argument("--slug")
    p.add_argument("--run")
    p.add_argument("--explain", action="store_true")
    sub = p.add_subparsers(dest="command")
    q = sub.add_parser("init")
    q.add_argument("--host", choices=("codex", "claude"), required=True)
    q.add_argument("--parent-id", required=True)
    q.add_argument("--check", action="append", default=[])
    q = sub.add_parser("target")
    q.add_argument("--output", required=True)
    q.add_argument(
        "--since",
        help="an earlier manifest token; adds the changed files and keeps the full manifest",
    )
    q = sub.add_parser("bind")
    q.add_argument("--role", choices=("right",), default="right")
    q.add_argument("--agent-id", required=True)
    q = sub.add_parser("prepare")
    q.add_argument("--sender", choices=ROLES, required=True)
    q.add_argument("--key", required=True)
    add_budget_flags(q)
    source = q.add_mutually_exclusive_group(required=True)
    source.add_argument("--message-file")
    source.add_argument("--stdin", action="store_true")
    q = sub.add_parser("receipt")
    q.add_argument("--message-id", required=True)
    q.add_argument("--state", choices=RECEIPT_STATES, required=True)
    q.add_argument("--actor-id", required=True)
    q.add_argument("--evidence")
    q = sub.add_parser("check")
    q.add_argument("--name", required=True)
    q.add_argument("--state", choices=("passed", "failed", "incomplete"), required=True)
    q.add_argument("--target", required=True)
    q.add_argument("--evidence", required=True)
    q = sub.add_parser("finalize")
    q.add_argument("--target", required=True)
    q.add_argument("--actor-id", required=True)
    q.add_argument("--evidence", required=True)
    add_timer_commands(sub)
    sub.add_parser("status")
    return p


def topic_path(repo, resolved, slug):
    require(
        slug is not None and SLUG.fullmatch(slug),
        "--slug must be 1-60 lowercase letters, digits or hyphens",
    )
    root = (repo / resolved["values"]["state_dir"] / slug).resolve()
    require(root.is_relative_to(repo), "topic path escapes project")
    return root, root / "state.json"


def run(args):
    repo = repo_path(args.repo)
    resolved = config(repo)
    if args.explain:
        return resolved
    require(args.command is not None, "specify a command or --explain")
    root, path = topic_path(repo, resolved, args.slug)
    if args.command == "status":
        return existing_status(args, path)
    if args.command == "prepare":
        args.body = (
            sys.stdin.read(1024 * 1024 + 1)
            if args.stdin
            else Path(args.message_file).read_text()
        )
        require(len(args.body.encode()) <= 1024 * 1024, "message exceeds 1 MiB")
    # Mutable conversation state must never appear in git status/add by default.
    ignored_path(repo, path)
    require(
        not git(repo, "ls-files", "--", str(root.relative_to(repo))),
        "state directory contains tracked files",
    )
    if args.command == "init":
        return init(args, repo, path)
    require(path.is_file(), "topic does not exist; init first")
    store = ps.open_topic(
        path,
        transport="bg",
        slug=args.slug,
        host=json.loads(path.read_text())["host"],
        repo=repo,
    )
    require(store.read()["repo"] == str(repo), "topic belongs to a different project")
    return mutate(args, store, repo, resolved["profile"])


def existing_status(args, path):
    require(path.is_file(), "topic does not exist")
    store = ps.Store(path)
    require(
        store.read().get("schema") == ps.SCHEMA,
        "topic is schema 1; run any mutating command to migrate it",
    )
    result = status_of(store)
    require(not args.run or args.run == result["run_id"], "stale --run identity")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        print(json.dumps(run(args), ensure_ascii=False))
        return 0
    except (
        Refusal,
        ps.StateError,
        LedgerRefusal,
        OSError,
        ValueError,
        KeyError,
        TypeError,
    ) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
