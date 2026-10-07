#!/usr/bin/env python3
"""Package one build protocol into independent Claude/Codex plugin caches."""
from pathlib import Path
import argparse
import sys

ROOT = Path(__file__).resolve().parent.parent


def outputs():
    template = (ROOT / "shared/peer-chat/build.md").read_text()
    for plugin, peer, engine, lifecycle in (
        ("peer-chat", "peer in the other pane",
         '1. `Skill(skill="peer-chat:peer-chat")`, then its Preflight.\n'
         '2. Peer: the skill\'s spawn step; `--peer <harness[:model]>` passes through. `"state":"already"` is fine.',
         "Continue independent work after sending; otherwise end the turn and let the reply resume it. Never poll a pane."),
        ("peer-chat-bg", "background peer",
         '1. Load `peer-chat-bg:peer-chat` (Claude: `Skill`; Codex: read `../peer-chat/SKILL.md` relative to this skill).\n'
         '2. Complete its preflight and bind the returned native child identity. `--peer` selects a host-supported model, not another runtime.',
         "Continue independent work after sending. Use the host completion/yield mechanism; use a bounded native wait only when the next step is blocked. Do not loop-poll."),
    ):
        rendered = template.replace("@PLUGIN@", plugin).replace("@PEER@", peer).replace("@ENGINE@", engine).replace("@LIFECYCLE@", lifecycle)
        rendered = rendered.replace("@ARTIFACT_ROOT@", "tmp/peer-chat-bg" if plugin == "peer-chat-bg" else "tmp/peer-chat").replace("@ASK_STATE@", "state.json" if plugin == "peer-chat-bg" else "asks.tsv")
        if plugin == "peer-chat-bg":
            rendered = rendered.replace("## Input", "The paths below use the default `tmp/peer-chat-bg`. Substitute `values.state_dir` from `BG --explain` when configured. The ask/message ledger is `<state_dir>/<slug>/state.json`, not a TSV file. Use the engine's target/check/finalize commands to validate the unchanged integrated tree and close both peer confirmations.\n\n## Input")
            rendered = rendered.replace("a sha, or the frozen list with hashes", "a validated `git:<full-sha>` token on a clean HEAD, or the `manifest:<path>#<sha256>` token returned by the engine's `target --output` command")
        header = "<!-- Generated from shared/peer-chat/build.md; edit the source and run scripts/sync-peer-chat-protocol.py. -->\n\n"
        frontmatter, body = rendered.split("---\n", 2)[1:]
        yield ROOT / f"plugins/{plugin}/commands/build.md", "---\n" + frontmatter + "---\n" + header + body.lstrip()
        codex_front = "---\nname: build\ndescription: Implement an agreed design with a peer through accepted lanes, frozen cross-review targets and recorded QA.\n---\n"
        yield ROOT / f"plugins/{plugin}/skills/build/SKILL.md", codex_front + header + "Start only when the user requests implementation of an agreed design. In a host without the `Skill` tool, load `../peer-chat/SKILL.md` relative to this file instead of calling `Skill`.\n\n" + body.lstrip()


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
