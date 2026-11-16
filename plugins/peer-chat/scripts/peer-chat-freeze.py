#!/usr/bin/env python3
"""Freeze a review target as one git tree sha and print the diff the reviewer reads since the last freeze.

peer-chat-freeze.py --slug <slug> [--dir <path>] [-- <pathspec>...]

A freeze writes the working tree, untracked files included, through a scratch copy of the index: the real
index, HEAD and the branch stay untouched. Each freeze records its repository in the topic's
state.json and prints the previous freeze from that same worktree, else its HEAD.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import freeze_tree, repo_root  # noqa: E402
from peer_chat_state import StateError, Store, open_topic, record_freeze

def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--slug", required=True)
    parser.add_argument("--dir", type=Path)
    parser.add_argument("--state", type=Path, help="the coordinator topic's state.json, including from another repo")
    parser.add_argument("pathspecs", nargs="*")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        repo = repo_root().resolve()
        path = (args.state or (args.dir or repo / "tmp/peer-chat" / args.slug) / "state.json").resolve()
        if path.name != "state.json":
            raise StateError("--state must name a topic's state.json")
        coordinator = Path(Store(path).read()["repo"]) if path.exists() else repo
        store = open_topic(path, transport="agterm", slug=args.slug, host="agterm", repo=coordinator,
                           legacy_dir=path.parent)
        tree = freeze_tree(repo, args.pathspecs)
        row = record_freeze(store, repo, tree, args.pathspecs)
        print(json.dumps({**row, "freeze": row["n"], "state": str(path), "ledger": str(path),
                          "diff": f'git diff {row["previous"]} {tree}'}))
        return 0
    except (StateError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"peer-chat-freeze: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
