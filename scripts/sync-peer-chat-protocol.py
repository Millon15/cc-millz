#!/usr/bin/env python3
"""Package one build protocol into independent Claude/Codex plugin caches."""

from pathlib import Path
import argparse
import sys

ROOT = Path(__file__).resolve().parent.parent
SKILL_DESCRIPTION = "Implement an agreed design with a peer through accepted lanes, frozen cross-review targets and recorded QA."


FRESH = {
    "peer-chat": (
        "Claude Code in agterm, after a long conversation. Run\n"
        "   `peer-chat-fresh.sh --focus \"<slug> build, design at <absolute design path>\" --resume\n"
        "   \"/peer-chat:build <absolute design path> --slug <slug>\"` and end the turn: once the turn is over it\n"
        "   types `/compact`, waits for the compaction, then types the resume line, each submitted by a\n"
        "   separate Return. Exit 3 (another harness, no agterm, no session id): continue in this context."
    ),
    "peer-chat-bg": (
        "none in this engine; after a long conversation the user may run `/compact`, then this\n"
        "   command again on the snapshot."
    ),
}

FREEZE = {
    "peer-chat": (
        "- Freeze a review target: the integrator commits it when the user's instructions and the project's\n"
        "  policy allow a commit now; otherwise `peer-chat-freeze.py --slug <slug> -- <lane files>` (add\n"
        "  `--dir <task dir>` when the snapshot lives outside the repo) prints the tree sha, untracked files\n"
        "  included, and the `git diff <previous> <tree>` the reviewer reads. Edits pause until the findings\n"
        "  arrive. `🎯 lane <n> ready for review: <tree>` with that diff command; a re-freeze after fixes\n"
        "  sends only its new diff."
    ),
    "peer-chat-bg": (
        "- Freeze a review target: the integrator commits it when the user's instructions and the project's\n"
        "  policy allow a commit now; otherwise the engine's `target --output <fresh path>`, with\n"
        "  `--since <previous token>` on a re-freeze so its `changed` list names the only files to re-read.\n"
        "  Edits pause until the findings arrive. `🎯 lane <n> ready for review: <token>`."
    ),
}


def invocation_keys(frontmatter):
    """Top-level frontmatter lines minus the multi-line description."""
    kept, in_description = [], False
    for line in frontmatter.splitlines(keepends=True):
        if not line.startswith(" "):
            in_description = line.startswith("description:")
        if not in_description:
            kept.append(line)
    return "".join(kept)


def outputs():
    template = (ROOT / "shared/peer-chat/build.md").read_text()
    for plugin, peer, engine, lifecycle in (
        (
            "peer-chat",
            "peer in the other pane",
            '1. `Skill(skill="peer-chat:peer-chat")`, then its Preflight.\n'
            '2. Peer: the skill\'s spawn step; `--peer <harness[:model]>` passes through. `"state":"already"` is fine.',
            "Continue independent work after sending; otherwise end the turn and let the reply resume it. Never poll a pane.",
        ),
        (
            "peer-chat-bg",
            "background peer",
            "1. Load `peer-chat-bg:peer-chat` (Claude: `Skill`; Codex: read `../peer-chat/SKILL.md` relative to this skill).\n"
            "2. Complete its preflight and bind the returned native child identity. `--peer` selects a host-supported model, not another runtime.",
            "Continue independent work after sending. Use the host completion/yield mechanism; use a bounded native wait only when the next step is blocked. Do not loop-poll.",
        ),
    ):
        rendered = (
            template.replace("@PLUGIN@", plugin)
            .replace("@PEER@", peer)
            .replace("@ENGINE@", engine)
            .replace("@LIFECYCLE@", lifecycle)
            .replace("@FRESH@", FRESH[plugin])
            .replace("@FREEZE@", FREEZE[plugin])
        )
        rendered = rendered.replace(
            "@ARTIFACT_ROOT@",
            "tmp/peer-chat-bg" if plugin == "peer-chat-bg" else "tmp/peer-chat",
        ).replace(
            "@ASK_STATE@", "state.json" if plugin == "peer-chat-bg" else "asks.tsv"
        )
        if plugin == "peer-chat-bg":
            rendered = rendered.replace(
                "## Input",
                "The paths below use the default `tmp/peer-chat-bg`. Substitute `values.state_dir` from `BG --explain` when configured. The ask/message ledger is `<state_dir>/<slug>/state.json`, not a TSV file. Use the engine's target/check/finalize commands to validate the unchanged integrated tree and close both peer confirmations.\n\n## Input",
            )
            rendered = rendered.replace(
                "a commit or tree sha",
                "a validated `git:<full-sha>` token on a clean HEAD, or the `manifest:<path>#<sha256>` token returned by the engine's `target --output` command",
            )
        header = "<!-- Generated from shared/peer-chat/build.md; edit the source and run scripts/sync-peer-chat-protocol.py. -->\n\n"
        frontmatter, body = rendered.split("---\n", 2)[1:]
        skill_front = (
            f"---\nname: build\ndescription: {SKILL_DESCRIPTION}\n"
            + invocation_keys(frontmatter)
            + "---\n"
        )
        yield (
            ROOT / f"plugins/{plugin}/skills/build/SKILL.md",
            skill_front
            + header
            + "Start only when the user requests implementation of an agreed design. In a host without the `Skill` tool, load `../peer-chat/SKILL.md` relative to this file instead of calling `Skill`.\n\n"
            + body.lstrip(),
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for path, body in outputs():
        if args.check:
            if not path.exists() or path.read_text() != body:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
    if stale:
        print("out of sync: " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
