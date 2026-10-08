#!/usr/bin/env python3
"""Durable native-peer protocol. Records evidence; never launches or impersonates a host tool."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import asdict
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace
import uuid

sys.dont_write_bytecode = True  # --explain must not populate the installed cache either.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import (Ask, Ledger, LedgerRefusal, Plan, ASK_ID_RE,
    clean_lines, is_ask, now_utc, parse_dispositions, peer_of, plan_body, stamp)

ROLES = ("left", "right")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,59}\Z")
TERMINAL = {"acknowledged", "answered", "failed", "cancelled"}
TRANSITIONS = {
    "prepared": {"dispatching", "cancelled"},
    "dispatching": {"submitted", "uncertain", "acknowledged", "answered", "failed"},
    "submitted": {"acknowledged", "answered", "uncertain"},
    "uncertain": {"submitted", "acknowledged", "answered", "failed"},
    "acknowledged": {"answered"},
    "answered": set(), "failed": set(), "cancelled": set(),
}


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
        require(not (set(data) - {"state_dir"}), "unknown profile keys")
        if "state_dir" in data:
            values["state_dir"] = data["state_dir"]
            sources["state_dir"] = "profile"
    require((repo / ".git").exists() or profile.exists(),
            "no project markers found: .git or .peer-chat-bg.json; pass --repo")
    value = values["state_dir"]
    require(isinstance(value, str) and value and not Path(value).is_absolute()
            and ".." not in Path(value).parts and value != ".", "state_dir must be a relative project path")
    root = (repo / value).resolve()
    require(root.is_relative_to(repo) and root != repo, "state_dir escapes project")
    return {"plugin": "peer-chat-bg", "profile_file": str(profile) if profile.exists() else None,
            "values": values, "sources": sources}


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


def freeze_target(repo, value):
    path = Path(value)
    if not path.is_absolute():
        path = repo / path
    path = path.resolve()
    require(path.is_relative_to(repo), "target manifest must be inside the project")
    ignored_path(repo, path)
    require(not path.exists(), "target manifest exists; freeze to a fresh file")
    frozen = tree_snapshot(repo)
    data = (json.dumps(frozen, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    token = "manifest:" + str(path.relative_to(repo)) + "#" + digest(data)
    return {"target": token, "manifest": str(path), "files": len(frozen["files"])}


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
    require(json.loads(data) == tree_snapshot(repo), "target working tree changed; freeze a new target and re-run checks")


def validate_evidence(record):
    path = Path(record["path"])
    require(path.is_file() and digest(path.read_bytes()) == record["sha256"], "evidence changed or disappeared: " + str(path))


def write_state(path, state):
    # One atomic snapshot contains messages, counters, asks and checks. A separate
    # lock file survives os.replace, unlike a lock held on the replaced state inode.
    temp = path.with_name(".state-" + uuid.uuid4().hex + ".tmp")
    try:
        with temp.open("x", encoding="utf-8") as stream:
            os.chmod(temp, 0o600)
            json.dump(state, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


@contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


class MemoryLedger(Ledger):
    """Reuse the canonical ask parser/planner against the locked native snapshot."""
    def __init__(self, state):
        self.state = state

    def load(self):
        return [Ask(**row) for row in self.state["asks"]]

    def next_id(self, agent):
        return f'{agent}-{self.state["counters"][agent] + 1:03d}'


def validate_dispositions(state, sender, plan):
    asks = {ask["id"]: ask for ask in state["asks"]}
    seen = set()
    for disposition in plan.dispositions:
        require(disposition.id not in seen, "duplicate disposition: " + disposition.id)
        seen.add(disposition.id)
        require(disposition.id in asks, "unknown ask: " + disposition.id)
        ask = asks[disposition.id]
        require(ask["asked_by"] != sender, "cannot dispose your own ask: " + disposition.id)
        require(ask["disposition"] in ("", "deferred"), "ask already closed: " + disposition.id)
        require(disposition.kind == "answered" or disposition.reason,
                "deferred/declined requires a reason: " + disposition.id)


def actor_role(state, actor):
    roles = [role for role, binding in state["bindings"].items()
             if binding and binding["agent_id"] == actor]
    require(len(roles) == 1, "actor ID does not identify a bound peer in this run")
    return roles[0]


def message_plan(message):
    return Plan(message["text"], [tuple(row) for row in message["new_asks"]],
                parse_dispositions(message["text"].splitlines()))


def activate_asks(state, message):
    if message["asks_active"]:
        return
    state["asks"] += [asdict(Ask(ask_id, message["sender"], stamp(now_utc()), "", "", "", question))
                      for ask_id, question in message["new_asks"]]
    message["asks_active"] = True


def apply_dispositions(state, message):
    if message["dispositions_applied"]:
        return
    plan = message_plan(message)
    validate_dispositions(state, message["sender"], plan)
    asks = Ledger.apply_dispositions(MemoryLedger(state).load(), plan.dispositions, now_utc())
    state["asks"] = [asdict(ask) for ask in asks]
    message["dispositions_applied"] = True


def snapshot(state, path):
    return {**state, "state_file": str(path),
            "open_asks": [ask["id"] for ask in state["asks"] if ask["disposition"] not in ("answered", "declined")],
            "unresolved_messages": [mid for mid, message in state["messages"].items() if message["state"] not in TERMINAL]}


def init(args, repo, path):
    if path.exists():
        state = json.loads(path.read_text())
        require(state["repo"] == str(repo) and state["host"] == args.host
                and state["bindings"]["left"]["agent_id"] == args.parent_id,
                "topic exists with different identity; use a fresh slug")
        require(set(args.check) == set(state["checks"]), "topic exists with a different required-check set")
        return snapshot(state, path), False
    require(args.parent_id.strip(), "parent ID is empty")
    require(all(name.strip() for name in args.check), "check names cannot be empty")
    state = {"schema": 1, "run_id": uuid.uuid4().hex, "slug": args.slug, "repo": str(repo),
             "host": args.host, "created_at": stamp(now_utc()), "phase": "active",
             "bindings": {"left": {"agent_id": args.parent_id, "generation": 1}, "right": None},
             "counters": {"left": 0, "right": 0}, "messages": {}, "keys": {}, "asks": [],
             "checks": {name: {"state": "incomplete"} for name in args.check}, "confirmations": {}}
    return snapshot(state, path), True


def mutate(args, state, repo):
    require(args.run == state["run_id"], "missing or stale --run identity; inspect status")
    require(state["phase"] == "active", "topic is finalized; use a fresh slug")
    if args.command == "target":
        return freeze_target(repo, args.output)
    if args.command == "bind":
        require(args.agent_id.strip(), "agent ID is empty")
        require(args.agent_id != state["bindings"]["left"]["agent_id"], "peer must not be the parent")
        prior = state["bindings"][args.role]
        require(not prior or prior["agent_id"] == args.agent_id,
                "role already bound; no silent identity replacement; use a fresh slug")
        state["bindings"][args.role] = {"agent_id": args.agent_id, "generation": 1}
        return {"run_id": state["run_id"], "role": args.role, **state["bindings"][args.role]}
    if args.command == "prepare":
        require(args.key.strip(), "idempotency key is empty")
        require(state["bindings"][args.sender], "sender role is not bound")
        body = args.body
        key = args.sender + ":" + args.key
        signature = digest(body.encode())
        if key in state["keys"]:
            message = state["messages"][state["keys"][key]]
            require(message["body_sha256"] == signature, "idempotency key reused with different content")
            return {**message, "replayed": True}
        lines = clean_lines(SimpleNamespace(label=f"Chat from {args.sender}: "), body)
        require(not any(is_ask(line) and ASK_ID_RE.search(line) for line in lines),
                "new asks must not supply their own IDs")
        ledger = MemoryLedger(state)
        plan = plan_body(lines, args.sender, ledger, now_utc(), width=0)
        validate_dispositions(state, args.sender, plan)
        state["counters"][args.sender] += len(plan.new_asks)
        mid = uuid.uuid4().hex
        message = {"message_id": mid, "run_id": state["run_id"], "sender": args.sender,
                   "recipient": peer_of(args.sender), "key": args.key, "body_sha256": signature,
                   "text": plan.text, "new_asks": plan.new_asks, "warnings": plan.warnings,
                   "state": "prepared", "asks_active": False, "dispositions_applied": False,
                   "created_at": stamp(now_utc()), "receipts": []}
        state["messages"][mid] = message
        state["keys"][key] = mid
        state["confirmations"] = {}
        return message
    if args.command == "receipt":
        require(args.message_id in state["messages"], "unknown message ID")
        message = state["messages"][args.message_id]
        role = actor_role(state, args.actor_id)
        desired = message["recipient"] if args.state in ("acknowledged", "answered") else message["sender"]
        require(role == desired, "receipt actor is not the " + desired + " peer")
        proof = None if args.state == "dispatching" else evidence(repo, args.evidence)
        matching = [receipt for receipt in message["receipts"] if receipt["state"] == args.state]
        if matching:
            require(any(receipt["actor_id"] == args.actor_id and receipt["evidence"] == proof
                        for receipt in matching), "same-state receipt differs from the recorded evidence")
            return {**message, "replayed": True, "dispatch_permitted": False}
        # A fast recipient can ACK before the sender persists the native call's
        # successful submission result. Keep the stronger state and retain that
        # late sender evidence; it is not a new dispatch or a state downgrade.
        late_submission = args.state == "submitted" and message["state"] in ("acknowledged", "answered")
        require(late_submission or args.state in TRANSITIONS[message["state"]],
                f'invalid receipt transition {message["state"]} -> {args.state}; never resend blindly')
        if args.state == "dispatching":
            binding = state["bindings"][message["recipient"]]
            require(binding is not None, "bind the actual recipient ID before dispatching")
            message["recipient_binding"] = dict(binding)
            plan = message_plan(message)
            validate_dispositions(state, message["sender"], plan)
            # Recheck asks received since prepare before authorizing a native call.
            from peer_chat_core import refuse_missing_dispositions
            refuse_missing_dispositions(MemoryLedger(state), message["sender"], plan)
            activate_asks(state, message)
        if args.state in ("submitted", "acknowledged", "answered"):
            apply_dispositions(state, message)
        if args.state == "failed":
            # "failed" means proved not delivered, not an ambiguous timeout. Do not
            # erase an ask already observed or answered by a concurrent peer.
            require(not message["dispositions_applied"], "already submitted; not-delivered classification contradicts prior receipt")
            own_ids = {row[0] for row in message["new_asks"]}
            touched = [ask for ask in state["asks"] if ask["id"] in own_ids and ask["disposition"]]
            require(not touched, "ask already observed; cannot classify message as not delivered")
            state["asks"] = [ask for ask in state["asks"] if ask["id"] not in own_ids]
        if not late_submission:
            message["state"] = args.state
        message["receipts"].append({"state": args.state, "actor_id": args.actor_id,
                                    "at": stamp(now_utc()), "evidence": proof})
        return {**message, "dispatch_permitted": args.state == "dispatching"}
    if args.command == "check":
        require(args.name in state["checks"], "check was not declared by init")
        validate_target(repo, args.target)
        state["checks"][args.name] = {"state": args.state, "target": args.target,
                                      "evidence": evidence(repo, args.evidence), "at": stamp(now_utc())}
        state["confirmations"] = {}
        return {"name": args.name, **state["checks"][args.name]}
    if args.command == "finalize":
        role = actor_role(state, args.actor_id)
        validate_target(repo, args.target)
        require(state["bindings"]["right"], "peer is not bound")
        require(all(ask["disposition"] in ("answered", "declined") for ask in state["asks"]), "open or deferred asks remain")
        require(all(message["state"] in TERMINAL for message in state["messages"].values()), "unresolved message receipts remain")
        require(all(check["state"] == "passed" and check["target"] == args.target
                    for check in state["checks"].values()), "required checks incomplete, failed or on a different target")
        require(all(any(message["sender"] == sender and message["state"] in ("acknowledged", "answered")
                            for message in state["messages"].values()) for sender in ROLES),
                "no two-way peer exchange; an ACK alone is not a substantive reply")
        for check in state["checks"].values():
            validate_evidence(check["evidence"])
        for confirmation in state["confirmations"].values():
            validate_evidence(confirmation["evidence"])
        other = state["confirmations"].get(peer_of(role))
        require(not other or other["target"] == args.target, "peers confirmed different final targets")
        state["confirmations"][role] = {"target": args.target, "actor_id": args.actor_id,
                                        "evidence": evidence(repo, args.evidence), "at": stamp(now_utc())}
        if len(state["confirmations"]) == 2:
            state["phase"] = "finalized"
            state["finalized_at"] = stamp(now_utc())
        return {"run_id": state["run_id"], "phase": state["phase"], "confirmations": state["confirmations"]}
    raise Refusal("unknown command")


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
    q = sub.add_parser("bind")
    q.add_argument("--role", choices=("right",), default="right")
    q.add_argument("--agent-id", required=True)
    q = sub.add_parser("prepare")
    q.add_argument("--sender", choices=ROLES, required=True)
    q.add_argument("--key", required=True)
    source = q.add_mutually_exclusive_group(required=True)
    source.add_argument("--message-file")
    source.add_argument("--stdin", action="store_true")
    q = sub.add_parser("receipt")
    q.add_argument("--message-id", required=True)
    q.add_argument("--state", choices=tuple(TRANSITIONS)[1:], required=True)
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
    sub.add_parser("status")
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        repo = repo_path(args.repo)
        resolved = config(repo)
        if args.explain:
            print(json.dumps(resolved))
            return 0
        require(args.command is not None, "specify a command or --explain")
        require(args.slug is not None and SLUG.fullmatch(args.slug), "--slug must be 1-60 lowercase letters, digits or hyphens")
        root = (repo / resolved["values"]["state_dir"] / args.slug).resolve()
        require(root.is_relative_to(repo), "topic path escapes project")
        path = root / "state.json"
        if args.command == "status":
            require(path.is_file(), "topic does not exist")
            state = json.loads(path.read_text())
            require(not args.run or args.run == state["run_id"], "stale --run identity")
            print(json.dumps(snapshot(state, path), ensure_ascii=False))
            return 0
        if args.command == "prepare":
            args.body = sys.stdin.read(1024 * 1024 + 1) if args.stdin else Path(args.message_file).read_text()
            require(len(args.body.encode()) <= 1024 * 1024, "message exceeds 1 MiB")
        # Mutable conversation state must never appear in git status/add by default.
        ignored_path(repo, path)
        require(not git(repo, "ls-files", "--", str(root.relative_to(repo))), "state directory contains tracked files")
        with locked(path):
            if args.command == "init":
                result, changed = init(args, repo, path)
                if changed:
                    state = {key: value for key, value in result.items()
                             if key not in ("state_file", "open_asks", "unresolved_messages")}
                    write_state(path, state)
            else:
                require(path.is_file(), "topic does not exist; init first")
                state = json.loads(path.read_text())
                require(state["repo"] == str(repo), "topic belongs to a different project")
                result = mutate(args, state, repo)
                write_state(path, state)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (Refusal, LedgerRefusal, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
