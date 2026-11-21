#!/usr/bin/env python3
"""Package the shared design and build protocols into both peer plugins."""

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
        "   separate Return. Exit 3 (another harness, no agterm, no session id): continue in this context.\n"
        "   Carry any explicit `--state <path>` in the resume line as well."
    ),
    "peer-chat-bg": (
        "none in this engine; after a long conversation the user may run `/compact`, then this\n"
        "   command again on the snapshot."
    ),
}

ARTIFACT_ROOT = {
    "peer-chat": "tmp/peer-chat",
    "peer-chat-bg": "tmp/peer-chat-bg",
}

BUILD_COORDINATOR = {
    "peer-chat": (
        "An optional `--state <path>` names the coordinator's existing `state.json`. Parse it as a flag\n"
        "before resolving the design input. Verify the state and use its repo for Phase 0. When the flag\n"
        "is omitted, use the initiator's topic state. For a build spanning repositories, name one\n"
        "coordinator state path in the opening message. Every lane passes that path with `--state`\n"
        "on sends and freezes from another repo. Preserve the coordinator across resume."
    ),
    "peer-chat-bg": (
        "Resolve `values.state_dir` with `BG --explain`. A Design proposal's reserved checks are\n"
        "`acceptance` and `security`. Record the acceptance check as passed only when its evidence\n"
        "records every proposal check passing."
    ),
}

DESIGN_TOPIC = {
    "peer-chat": (
        "Use the coordinator's `tmp/peer-chat/<slug>/` and verify Git ignores the directory and\n"
        "tracks no files there. When sending or reading status from another repo, pass the same\n"
        "`--state <coordinator topic>/state.json`. Read the ledger with `peer-chat-state.py ... status`."
    ),
    "peer-chat-bg": (
        "Read `values.state_dir` from `BG --explain`. Use its ignored `<slug>/` topic directory.\n"
        "For a new design run, reserve `--check acceptance --check security` at `BG ... init` so Build\n"
        "can reuse the same run. Keep the coordinator `--repo`, `--slug`, `--run` and native peer bound.\n"
        "Read the ledger with `BG ... status`."
    ),
}

DESIGN_HANDOFF = {
    "peer-chat": (
        "Invoke\n  `/peer-chat:build <absolute proposal path> --slug <same slug>`. "
        "Include `--state <coordinator state path>`\n  for a cross-repo build."
    ),
    "peer-chat-bg": (
        "Invoke\n  `/peer-chat-bg:build <absolute proposal path> --slug <same slug>` in the coordinator repo, "
        "preserving its\n  run ID, peer identity and state directory."
    ),
}

FREEZE = {
    "peer-chat": (
        "- Freeze a review target: the integrator commits it when the user's instructions and the project's\n"
        "  policy allow a commit now; otherwise `peer-chat-freeze.py --slug <slug> -- <lane files>` (add\n"
        "  `--dir <task dir>` when the snapshot lives outside the repo) prints the tree sha, untracked files\n"
        "  included. A lane in another repo passes `--state <coordinator topic>/state.json`; every send\n"
        "  of the build uses that same state path. Freeze history selects the previous tree from this\n"
        "  repository only. The output includes\n"
        "  the `git diff <previous> <tree>` the reviewer reads. Edits pause until the findings\n"
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

AGTERM_GATE = """
### Record the integrated target set

The integrator writes an ignored JSON spec with every repository and its required check names:
`{"repos":[{"repo":"/absolute/worktree","checks":["suite","security"]}]}`. Include the coordinator.
Run `peer-chat-state.py --slug <slug> --state <coordinator state> target --spec <spec path>`;
its `id` covers visible tracked/untracked file bytes, kinds, modes and the required checks
across the entire set. A changed target or required-check set clears both confirmations and checks.
Record each actual result using `... check --repo <worktree> --name <check>
--state passed|failed|incomplete --target-set <id> --evidence <receipt>`. Receipts stay inside
the coordinator's ignored topic directory. Committing exactly the checked files preserves the id;
any hook-induced edit still requires a fresh target and checks.

During Phase 5, exchange the closing messages and record each recipient's actual observed peer
text with `... observe --message-id <id> --event acknowledged|answered --actor-id <recipient>
--evidence <received text>`. Pasted text and a submit key cannot finalize a build.
Both peers then run `... confirm --target-set <id> --actor-id <own identity> --evidence <proof>`;
the integrator runs `... finalize --target-set <id> --actor-id <own identity>`. Finalize rechecks
all repository snapshots and evidence hashes, requires zero open asks, unresolved messages,
timer intents or unreleased stopped scopes, passed checks and both current confirmations.
Completion requires `phase: finalized`. Any later file edit needs a new target and checks.
"""


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
    design = (ROOT / "shared/peer-chat/design.md").read_text()
    for plugin, peer, engine, lifecycle in (
        (
            "peer-chat",
            "peer in the other pane",
            '1. `Skill(skill="peer-chat:peer-chat")`, then its Preflight.\n'
            '2. Peer: the skill\'s spawn step with `<peer>`, its model mapped as the skill\'s § Bringing a peer in says. `"state":"already"` is fine, except for a model the user named: the skill\'s restart rule applies.',
            "Continue independent work after sending; otherwise end the turn and let the reply resume it. An ask the next step needs arms the skill's timer (§ A stalled ask); never poll a pane.",
        ),
        (
            "peer-chat-bg",
            "background peer",
            "1. Load `peer-chat-bg:peer-chat` (Claude: `Skill`; Codex: read `../peer-chat/SKILL.md` relative to this skill).\n"
            "2. Apply its Peer selection rules to `<peer>` or `--peer`, complete preflight and bind the returned native child identity. Without a model, the child inherits; a different runtime is refused.",
            "Continue independent work after sending. Use the host completion/yield mechanism; use a bounded native wait only when the next step is blocked. Do not loop-poll.",
        ),
    ):
        rendered = (
            template.replace("@PLUGIN@", plugin)
            .replace("@PEER@", peer)
            .replace("@ENGINE@", engine)
            .replace("@LIFECYCLE@", lifecycle)
            .replace("@FRESH@", FRESH[plugin])
            .replace("@BUILD_STATE_ARGUMENT@", " [--state <path>]" if plugin == "peer-chat" else "")
            .replace("@BUILD_COORDINATOR@", BUILD_COORDINATOR[plugin])
            .replace("@FREEZE@", FREEZE[plugin])
            .replace("@GATE@", AGTERM_GATE if plugin == "peer-chat" else "")
        )
        rendered = rendered.replace(
            "@ARTIFACT_ROOT@", ARTIFACT_ROOT[plugin],
        ).replace(
            "@ASK_STATE@", "state.json"
        )
        if plugin == "peer-chat-bg":
            rendered = rendered.replace(
                "## Engine\n\n",
                "## Engine\n\n"
                "For a Design handoff, verify and reuse its coordinator repo, run ID and bound peer. "
                "Load the engine below and resume that peer. Start and bind a peer only for a new run.\n\n",
            )
            rendered = rendered.replace(
                "## Input",
                "The paths below use the default `tmp/peer-chat-bg`. Substitute `values.state_dir` from `BG --explain` when configured. The ask/message ledger is `<state_dir>/<slug>/state.json`, not a TSV file. Use the engine's target/check/finalize commands to validate the unchanged integrated tree and close both peer confirmations.\n\n## Input",
            )
            rendered = rendered.replace(
                "a commit or tree sha",
                "a validated `git:<full-sha>` token on a clean HEAD, or the `manifest:<path>#<sha256>` token returned by the engine's `target --output` command",
            )
        else:
            rendered = rendered.replace("a commit or tree sha", "the `target_set` id covering every repository and its required checks")
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
        frontmatter, body = (
            design.replace("@PLUGIN@", plugin)
            .replace("@PEER@", peer)
            .replace("@ENGINE@", engine)
            .replace("@LIFECYCLE@", lifecycle)
            .replace("@DESIGN_TOPIC@", DESIGN_TOPIC[plugin])
            .replace("@ASK_STATE@", "state.json")
            .replace("@DESIGN_HANDOFF@", DESIGN_HANDOFF[plugin])
        ).split("---\n", 2)[1:]
        yield (
            ROOT / f"plugins/{plugin}/skills/design/SKILL.md",
            "---\n" + frontmatter + "---\n"
            + "<!-- Generated from shared/peer-chat/design.md; edit the source and run scripts/sync-peer-chat-protocol.py. -->\n\n"
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
