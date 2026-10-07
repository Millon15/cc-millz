---
description: >
  Implement the proposed design with the @PEER@, through cross-review and QA:
  snapshot the design to one task file, cut it into two lanes with disjoint files, written seam
  contracts and an integrator, get the split accepted, build in parallel, review frozen targets,
  fix by owner, record every acceptance check, commit under the project's policy. Use after a
  design is agreed in chat, a plan file or a ticket: "implement the design with the peer",
  "build this with codex", "pair on the implementation".
argument-hint: "[<design file | ticket url or key>] [--slug <topic>] [--peer <harness[:model]>]"
disable-model-invocation: true
model: opus
---

# `/@PLUGIN@:build`

Implement a design that already exists, in this session, with the @PEER@. The
`@PLUGIN@` skill is the engine: transport, asks, ownership, proofs and host lifecycle. This command
adds the build flow; where the two disagree, the skill wins.

## Engine

@ENGINE@

## Input

`$ARGUMENTS`: `[<design>] [--slug <topic>] [--peer <harness[:model]>]`. `<design>` is a file path, a
ticket url or key (fetched with the project's tracker tooling), or empty: the one proposal the user
approved in this conversation. Several incompatible proposals: ask the user which, before the first
send. `--slug` defaults to the design title in kebab-case, at most four words; every send of this
build carries it.

## Phase 0: Snapshot the design (HARD GATE)

Chat dies at the next compaction, the peer does not inherit the entire parent conversation, and the user's own file must not
grow orchestration state. Every input form gets ONE task file, written by the integrator only:

1. Location: `@ARTIFACT_ROOT@/<slug>/design.md` when `git check-ignore -q @ARTIFACT_ROOT@` exits 0,
   else `design.md` in a directory the integrator allocates with
   `mktemp -d "${TMPDIR:-/tmp}/peer-chat.<slug>.XXXXXX"`. An existing snapshot is never overwritten:
   resume that build or allocate a fresh slug. The opening message carries the absolute path.
2. Content: the design verbatim (sections, tables, acceptance checks, open decisions) plus a
   `Source:` line (chat, path, or ticket url). This is the skill's task-input exception
   (§ Artifacts): design, acceptance checks and lane agreement, nothing else.
3. Open decisions: a reversible implementation choice takes the design's recommendation, else the
   safer default, listed as `defaults taken`. A decision the user's authorization does not cover
   goes to the user before the first send.

Done when the file exists and `git status` shows the worktree you start from.

## Phase 1: Split and get it accepted

Two agents are two lanes, not five parallel activities. One opening message, mirrored into the
`## Lanes` section of the design file in state `proposed`:

- lanes: two, DISJOINT file sets; a file both need gets one owner, the other lane a contract.
- contracts: the exact shape at each seam, written out: CLI verb, flags, exit codes; JSON keys; a
  signature; a path.
- integrator: the agent that owns the design file, the git index, commits, pushes and every
  stateful QA resource (a database, a running stack); no edit right on the peer's files.
- project rules, one line each: worktree and branch, commit path, test command.
- assignment: you take the lane whose files you already read; the peer takes the rest.
- one `❓`: "accept or amend the split, contracts and integrator".

The peer's `accepted:` line flips `## Lanes` to `accepted` (the integrator writes it); only then do
lane edits start. Until then: read the code, write the QA cases, script the acceptance checks, run
the baseline tests; nothing independent left, end the turn and let the reply resume it. Silence
never accepts. A later contract amendment sits under `proposed` beside the last accepted contract
until its owner accepts it.

## Phase 2: Build

| Runs in parallel | Waits for |
| --- | --- |
| both lanes' implementation | `## Lanes` in state `accepted` |
| a review of one stable lane, the other lane's build | that lane's frozen target |
| both cross-reviews, both owners' fixes | both lanes stable |
| a re-verify of a fix | the fix |
| integrated QA | both lanes integrated, the final state |

- Own files only. A breaking seam change is a `🎯` first and gets the affected owner's `accepted:`
  before any dependent edit; unrelated work continues meanwhile.
- Self-check each lane with what the project has: typecheck, lint, the unit tests on its files.
- Freeze a review target: the integrator commits it when the user's instructions and the project's
  policy allow a commit now; otherwise the exact file list, untracked files included, each with its
  `shasum -a 256`, edits paused until the findings arrive.
  `🎯 lane <n> ready for review: <target>`.

## Phase 3: Cross-review

- Review the peer's frozen target against the accepted contracts and the design: one `🎯` per
  finding with a `🔎 path:line`, worst first; questions as `❓`.
- The owner fixes its own files. "fixed" quotes the re-run of the reviewer's proof (skill
  § Proofs),
  otherwise `🎯 unproven:`.

Done when both targets have zero open findings and the ledger zero open asks. A `declined` closes
an ask; the requirement behind it stays open until fixed or accepted within the user's scope.

## Phase 4: Prove

- Acceptance checks: every check the design names, on the integrated final state. None named:
  derive one per lane from the design's "done" wording and send it as a `🎯` before running it.
- The non-author runs a lane's check where the environment allows; the integrator runs anything
  stateful. Output lands under `@ARTIFACT_ROOT@/<slug>/NN-<role>-<what>.out`, cited in a `📎`.
- A red check returns the lane to Phase 2 for its owner.

Done when every acceptance check has a recorded outcome and every required one is green. A check
that could not run is `incomplete`, never green.

## Phase 5: Close

- Both peers name the same final target: a sha, or the frozen list with hashes, unchanged since
  the last green check and both confirmations.
- Commit and push only as the user's instructions and the project's policy allow, through the
  project's commit command or agent when one exists; the command grants no publish authority.
- `🏁` from both sides: commits, proof paths, leftovers and why. Report to the user: lanes,
  commits, recorded outcomes, leftovers, design path, ledger path.

## Guardrails

- MUST hold every lane edit until `## Lanes` reads `accepted`, on a first run and after a recovery.
- @LIFECYCLE@ Never claim completion while an ask is open.
- NEVER edit a file the peer owns: a patch through the skill's patch protocol instead.
- NEVER claim "fixed", "passes" or "works" from a reading: run it, or write `🎯 unproven:`.
- After compaction or an interruption: re-read the design file, `git status`, the diff and
  `@ASK_STATE@` before anything; a `## Lanes` not in `accepted` is re-agreed first.
- A peer agreement never widens what the user authorized (skill § Organizing the work).
