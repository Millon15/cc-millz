#!/usr/bin/env python3
"""Inspect a topic and record timer actions without driving either agent."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import now_utc, repo_root, stamp
from peer_chat_state import (
    CLOSED, PEER_EVENTS, TERMINAL_MESSAGES, StateError, Store, begin, due, evidence_record,
    finish, next_wake, nudge_submitted, observe, proof_of, relocate, release, status, unresolved_timers, withdraw,
)


def state_path(slug: str, explicit: str | None = None) -> Path:
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", slug):
        raise StateError("slug must be a single topic name")
    path = Path(explicit).expanduser().resolve() if explicit else repo_root() / "tmp/peer-chat" / slug / "state.json"
    if path.name != "state.json":
        raise StateError("--state must name a topic's state.json")
    return path


def parse_token(value: str) -> dict:
    try:
        token = json.loads(value)
    except json.JSONDecodeError as error:
        raise argparse.ArgumentTypeError("token must be a JSON object from wake") from error
    if not isinstance(token, dict):
        raise argparse.ArgumentTypeError("token must be a JSON object from wake")
    return token


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    cli.add_argument("--slug", required=True)
    cli.add_argument("--state")
    commands = cli.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("wake")
    for name in ("begin", "finish", "nudged"):
        command = commands.add_parser(name)
        command.add_argument("--token", type=parse_token, required=True)
        if name != "nudged":
            command.add_argument("--action", choices=("nudge", "stop"), required=True)
        if name == "finish":
            command.add_argument("--outcome", choices=("ok", "failed"), required=True)
            command.add_argument("--detail", default="")
    command = commands.add_parser("release")
    command.add_argument("--ask-id", required=True)
    command.add_argument("--evidence", type=Path, required=True)
    command = commands.add_parser("observe")
    command.add_argument("--message-id", required=True)
    command.add_argument("--event", choices=("submit_sent", "acknowledged", "answered", "failed", "cancelled", "uncertain"), required=True)
    command.add_argument("--evidence", type=Path, required=True)
    command.add_argument("--actor-id", required=True)
    command = commands.add_parser("relocate")
    command.add_argument("--message-id", required=True)
    command.add_argument("--event-index", type=int, required=True)
    command.add_argument("--actor-id", required=True)
    command.add_argument("--reason", required=True)
    command.add_argument("--evidence", type=Path, required=True)
    command = commands.add_parser("withdraw")
    command.add_argument("--ask-id", required=True)
    command.add_argument("--actor-id", required=True)
    command.add_argument("--reason", required=True)
    command.add_argument("--evidence", type=Path, required=True)
    command = commands.add_parser("target")
    command.add_argument("--spec", type=Path, required=True)
    command = commands.add_parser("check")
    command.add_argument("--repo", type=Path, required=True)
    command.add_argument("--name", required=True)
    command.add_argument("--state", dest="check_state", choices=("passed", "failed", "incomplete"), required=True)
    command.add_argument("--target-set", required=True)
    command.add_argument("--evidence", type=Path, required=True)
    for name in ("confirm", "finalize"):
        command = commands.add_parser(name)
        command.add_argument("--target-set", required=True)
        command.add_argument("--actor-id", required=True)
        if name == "confirm":
            command.add_argument("--evidence", type=Path, required=True)
    return cli


def require(condition, message: str) -> None:
    if not condition:
        raise StateError(message)


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True)
    require(result.returncode == 0, result.stderr.decode(errors="replace").strip() or "Git operation failed")
    return result.stdout


def worktree_root(path: Path) -> Path:
    return Path(os.fsdecode(git(path.expanduser().resolve(), "rev-parse", "--show-toplevel")).strip()).resolve()


def hash_json(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def file_snapshot(path: Path) -> dict:
    if path.is_symlink():
        return {"kind": "symlink", "mode": stat.S_IMODE(path.lstat().st_mode),
                "sha256": hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()}
    if not path.exists():
        return {"kind": "deleted"}
    require(path.is_file(), f"cannot snapshot a directory or submodule as a file: {path}")
    return {"kind": "file", "mode": stat.S_IMODE(path.stat().st_mode),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def repo_snapshot(repo: Path, paths: list[str] | None = None) -> dict:
    """Every visible file of the worktree, or only those under the literal `paths` of a scoped target."""
    scope = ("--literal-pathspecs",) if paths else ()
    listed = git(repo, *scope, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *(paths or ()))
    names = set(listed.split(b"\0")) - {b""}
    for name in names if paths else ():
        require(not symlinked_parent(repo, os.fsdecode(name)),
                f"scoped file {os.fsdecode(name)} resolves through a symlinked directory; scope the link itself")
    return {"files": {os.fsdecode(name): file_snapshot(repo / os.fsdecode(name)) for name in sorted(names)
                      if (repo / os.fsdecode(name)).exists() or (repo / os.fsdecode(name)).is_symlink()}}


def symlinked_parent(repo: Path, name: str) -> bool:
    return any((repo / parent).is_symlink() for parent in PurePosixPath(name).parents if str(parent) != ".")


def scope_path_valid(path) -> bool:
    return isinstance(path, str) and path != "" and not path.startswith("/") and ".." not in PurePosixPath(path).parts


def scope_paths(entry: dict) -> list[str] | None:
    if "paths" not in entry:
        return None
    paths = entry["paths"]
    require(isinstance(paths, list) and paths and all(scope_path_valid(path) for path in paths)
            and len(paths) == len(set(paths)), "paths must be a nonempty list of unique repo-relative paths without ..")
    return sorted(paths)


def repo_row(root: Path, names: list[str], paths: list[str] | None) -> dict:
    row = {"snapshot": repo_snapshot(root, paths), "required_checks": sorted(names)}
    return {**row, "paths": paths} if paths else row


def read_spec(path: Path, coordinator: Path) -> dict:
    source = path if path.is_absolute() else coordinator / path
    spec = json.loads(source.read_text())
    require(isinstance(spec, dict) and set(spec) == {"repos"} and isinstance(spec["repos"], list) and spec["repos"],
            "spec must contain a nonempty repos array")
    repos = {}
    for entry in spec["repos"]:
        require(isinstance(entry, dict) and set(entry) in ({"repo", "checks"}, {"repo", "checks", "paths"}),
                "each repo needs repo and checks, and may name paths")
        path = Path(entry["repo"])
        root = worktree_root(path if path.is_absolute() else coordinator / path)
        names = entry["checks"]
        require(isinstance(names, list) and names and all(isinstance(name, str) and name.strip() == name and name for name in names),
                "each repo needs nonempty check names")
        require(len(names) == len(set(names)), "duplicate required check")
        require(str(root) not in repos, "duplicate worktree in target spec")
        repos[str(root)] = repo_row(root, names, scope_paths(entry))
    return repos


def validate_state_location(store: Store, coordinator: Path) -> None:
    path = store.path.resolve()
    require(path.is_relative_to(coordinator), "topic state must be inside the coordinator")
    relative = str(path.relative_to(coordinator))
    ignored = subprocess.run(["git", "-C", str(coordinator), "check-ignore", "-q", "--", relative]).returncode == 0
    require(ignored and not git(coordinator, "ls-files", "--", relative), "topic state must be Git-ignored and untracked")


def capture_target(args: argparse.Namespace, store: Store) -> dict:
    before = store.read()
    require(before["phase"] == "active", "topic is finalized")
    coordinator = Path(before["repo"]).resolve()
    validate_state_location(store, coordinator)
    repos = read_spec(args.spec, coordinator)
    require(str(coordinator) in repos, "target spec must include the coordinator worktree")
    target = {"id": hash_json(repos), "repos": repos}
    with store.mutate() as state:
        require(state["run_id"] == before["run_id"] and state["phase"] == "active", "topic changed during capture")
        if state.get("target_set", {}).get("id") != target["id"]:
            state["target_set"] = target
            state["checks"] = {repo: {name: {"state": "incomplete"} for name in row["required_checks"]}
                               for repo, row in repos.items()}
            state["confirmations"] = {}
    return target


def current_target(state: dict, expected: str) -> dict:
    target = state.get("target_set")
    require(target and target["id"] == expected and hash_json(target["repos"]) == expected,
            "target set missing or changed; capture and check the current set")
    for name, entry in target["repos"].items():
        require(str(worktree_root(Path(name))) == name and repo_snapshot(Path(name), entry.get("paths")) == entry["snapshot"],
                f"target working tree changed: {name}; capture a new target and rerun checks")
    return target


def validate_evidence(state: dict, proof: dict) -> None:
    path = Path(proof["path"]).resolve()
    require(path.is_relative_to(Path(state["repo"]).resolve()), "evidence must remain inside the coordinator")
    require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == proof["sha256"],
            f"evidence changed or disappeared: {path}")


def actor_role(state: dict, actor: str) -> str:
    roles = [role for role, participant in state["participants"].items()
             if participant and participant["agent_id"] == actor]
    require(len(roles) == 1, "actor must identify one bound participant")
    return roles[0]


def record_check(args: argparse.Namespace, store: Store) -> dict:
    with store.mutate() as state:
        require(state["phase"] == "active", "topic is finalized")
        target = current_target(state, args.target_set)
        name = str(worktree_root(args.repo))
        require(name in target["repos"] and args.name in target["repos"][name]["required_checks"], "check was not declared")
        record = {"state": args.check_state, "target_set": args.target_set,
                  "evidence": evidence_record(state, args.evidence, store.path.parent), "at": stamp(now_utc())}
        state["checks"][name][args.name] = record
        state["confirmations"] = {}
        return record


def peer_exchange(state: dict) -> None:
    require(all(participant is not None for participant in state["participants"].values()), "bind both participants")
    require(all(ask["disposition"] in CLOSED for ask in state["asks"]), "open or deferred asks remain")
    require(not unresolved_timers(state), "timer intents or stopped peer scopes remain unresolved")
    exchanged = set()
    for message in state["messages"].values():
        require(message["state"] in TERMINAL_MESSAGES, "unresolved message receipts remain; keystrokes are not peer evidence")
        if message["state"] in PEER_EVENTS:
            require(any(event["event"] == message["state"] for event in message["events"]),
                    "terminal peer state has no corresponding evidence event")
        for event in message["events"]:
            if event["event"] in PEER_EVENTS:
                recipient = state["participants"][message["recipient"]]
                require(event["actor"] == recipient["agent_id"] and proof_of(event), "peer receipt has no bound recipient evidence")
                validate_evidence(state, proof_of(event))
                exchanged.add(message["sender"])
    require(exchanged == {"left", "right"}, "need a genuine two-way recipient-evidenced exchange")


def validate_supporting_evidence(state: dict) -> None:
    for message in state["messages"].values():
        for event in message["events"]:
            if proof_of(event):
                validate_evidence(state, proof_of(event))
    for row in state["asks"]:
        if row.get("withdrawal"):
            validate_evidence(state, row["withdrawal"]["evidence"])
    for timer in state["timers"].values():
        if timer.get("release"):
            validate_evidence(state, timer["release"]["evidence"])


def require_closable(state: dict, target: dict) -> None:
    peer_exchange(state)
    for repo, entry in target["repos"].items():
        for name in entry["required_checks"]:
            record = state["checks"].get(repo, {}).get(name, {})
            require(record.get("state") == "passed" and record.get("target_set") == target["id"],
                    f"required check incomplete, failed or on another target: {repo} {name}")
            validate_evidence(state, record["evidence"])
    validate_supporting_evidence(state)


def gate_action(args: argparse.Namespace, store: Store) -> dict:
    with store.mutate() as state:
        require(state["phase"] == "active", "topic is finalized")
        target = current_target(state, args.target_set)
        require_closable(state, target)
        role = actor_role(state, args.actor_id)
        if args.command == "confirm":
            participant = state["participants"][role]
            state["confirmations"][role] = {"target_set": target["id"], "actor_id": args.actor_id,
                                             "generation": participant["generation"],
                                             "evidence": evidence_record(state, args.evidence, store.path.parent), "at": stamp(now_utc())}
        else:
            require(set(state["confirmations"]) == {"left", "right"}, "both peers must confirm this target set")
        for who, record in state["confirmations"].items():
            participant = state["participants"][who]
            require(record["target_set"] == target["id"] and record["actor_id"] == participant["agent_id"]
                    and record["generation"] == participant["generation"], "confirmation is stale or belongs to another target")
            validate_evidence(state, record["evidence"])
        if args.command == "finalize":
            state["phase"] = "finalized"
            state["finalized_at"] = stamp(now_utc())
        return {"target_set": target["id"], "phase": state["phase"], "confirmations": state["confirmations"], "role": role}


def wake_status(store: Store) -> dict:
    moment = now_utc()
    timers = [timer for timer in store.read()["timers"].values()
              if timer["phase"] in ("armed", "nudged") and timer["intent"] is None]
    wake_at = next_wake(store, min(timer["budgets"]["wake"]["seconds"] for timer in timers), now=moment) if timers else None
    delay = max(0, (datetime.strptime(wake_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) - moment).total_seconds()) if wake_at else None
    return {"due": due(store, now=moment), "next_wake_at": wake_at,
            "wake_in_seconds": delay, "observed_at": stamp(moment)}


def run(args: argparse.Namespace, store: Store):
    if args.command == "target":
        return capture_target(args, store)
    if args.command == "check":
        return record_check(args, store)
    if args.command in ("confirm", "finalize"):
        return gate_action(args, store)
    if args.command == "status":
        return status(store)
    if args.command == "wake":
        return wake_status(store)
    if args.command == "begin":
        return begin(store, args.token, args.action)
    if args.command == "finish":
        return finish(store, args.token, args.action, args.outcome, detail=args.detail)
    if args.command == "nudged":
        return {"grace_expires_at": nudge_submitted(store, args.token)}
    if args.command == "release":
        return release(store, args.ask_id, args.evidence)
    if args.command == "relocate":
        return relocate(store, args.message_id, args.event_index, actor=args.actor_id, reason=args.reason,
                        evidence=args.evidence)
    if args.command == "withdraw":
        return withdraw(store, args.ask_id, actor=args.actor_id, reason=args.reason, evidence=args.evidence)
    return observe(store, args.message_id, args.event, evidence=args.evidence, actor=args.actor_id)


def main() -> int:
    args = parser().parse_args()
    try:
        store = Store(state_path(args.slug, args.state))
        state = store.read()
        if state.get("slug") != args.slug or state.get("transport") != "agterm":
            raise StateError("state does not belong to this agterm topic")
        print(json.dumps(run(args, store), ensure_ascii=False))
        return 0
    except (StateError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"peer-chat-state: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
