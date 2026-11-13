#!/usr/bin/env python3
"""Freeze a review target as one git tree sha and print the diff the reviewer reads since the last freeze.

peer-chat-freeze.py --slug <slug> [--dir <path>] [-- <pathspec>...]

A freeze writes the working tree, untracked files included, through a scratch copy of the index: the real
index, HEAD and the branch stay untouched. Each freeze appends one row to <dir>/freezes.tsv (default
tmp/peer-chat/<slug>/ under the repo root) and prints JSON: freeze number, tree sha, the previous target
(the last freeze, else HEAD) and the `git diff <previous> <tree>` command the reviewer runs.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peer_chat_core import freeze_tree, now_utc, repo_root, stamp  # noqa: E402

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--slug", required=True)
    parser.add_argument("--dir", type=Path)
    parser.add_argument("pathspecs", nargs="*")
    return parser.parse_args(argv)


def head_or_empty(repo: Path) -> str:
    probe = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--verify", "-q", "HEAD"],
        capture_output=True,
        text=True,
    )
    return probe.stdout.strip() or EMPTY_TREE


def previous_target(ledger: Path, repo: Path) -> str:
    rows = ledger.read_text().splitlines() if ledger.exists() else []
    return rows[-1].split("\t")[2] if rows else head_or_empty(repo)


def append_row(ledger: Path, tree: str, pathspecs: list[str]) -> int:
    ledger.parent.mkdir(parents=True, exist_ok=True)
    number = len(ledger.read_text().splitlines()) + 1 if ledger.exists() else 1
    with ledger.open("a") as stream:
        stream.write(
            f"{number}\t{stamp(now_utc())}\t{tree}\t{' '.join(pathspecs) or '.'}\n"
        )
    return number


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    repo = repo_root()
    ledger = (args.dir or repo / "tmp/peer-chat" / args.slug) / "freezes.tsv"
    previous = previous_target(ledger, repo)
    tree = freeze_tree(repo, args.pathspecs)
    number = append_row(ledger, tree, args.pathspecs)
    print(
        json.dumps(
            {
                "freeze": number,
                "tree": tree,
                "previous": previous,
                "diff": f"git diff {previous} {tree}",
                "ledger": str(ledger),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
