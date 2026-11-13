---
name: build
description: Implement an agreed design with a peer through accepted lanes, frozen cross-review targets and recorded QA.
argument-hint: "[<design file | ticket url or key>] [--slug <topic>] [--peer <harness[:model]>]"
model: opus
---
<!-- Generated from shared/peer-chat/build.md; edit the source and run scripts/sync-peer-chat-protocol.py. -->

Start only when the user requests implementation of an agreed design. In a host without the `Skill` tool, load `../peer-chat/SKILL.md` relative to this file instead of calling `Skill`.

# `/peer-chat:build`

Implement a design that already exists, in this session, with the peer in the other pane. The
`peer-chat` skill is the engine: transport, asks, ownership, proofs and host lifecycle. This command
adds the build flow; where the two disagree, the skill wins.

## Engine

1. `Skill(skill="peer-chat:peer-chat")`, then its Preflight.
2. Peer: the skill's spawn step; `--peer <harness[:model]>` passes through. `"state":"already"` is fine.

## Input

`$ARGUMENTS`: `[<design>] [--slug <topic>] [--peer <harness[:model]>]`. `<design>` is a file path, a
ticket url or key (fetched with the project's tracker tooling), or empty: the one proposal the user
approved in this conversation. Several incompatible proposals: ask the user which, before the first
send. `--slug` defaults to the design title in kebab-case, at most four words; every send of this
build carries it.

## Phase 0: Snapshot the design (HARD GATE)

Chat dies at the next compaction, the peer does not inherit the entire parent conversation, and the user's own file must not
grow orchestration state. Every input form gets ONE task file, written by the integrator only:

1. Location: `tmp/peer-chat/<slug>/design.md` when `git check-ignore -q tmp/peer-chat` exits 0,
   else `design.md` in a directory the integrator allocates with
   `mktemp -d "${TMPDIR:-/tmp}/peer-chat.<slug>.XXXXXX"`. An existing snapshot is never overwritten:
   resume that build or allocate a fresh slug. The opening message carries the absolute path.
2. Content: the design verbatim (sections, tables, acceptance checks, open decisions) plus a
   `Source:` line (chat, path, or ticket url). This is the skill's task-input exception
   (§ Artifacts): design, acceptance checks and lane agreement, nothing else.
3. Open decisions: a reversible implementation choice takes the design's recommendation, else the
   safer default, listed as `defaults taken`. A decision the user's authorization does not cover
   goes to the user before the first send.
4. Fresh context: Claude Code in agterm, after a long conversation. Run
   `peer-chat-fresh.sh --focus "<slug> build, design at <absolute design path>" --resume
   "/peer-chat:build <absolute design path> --slug <slug>"` and end the turn: once the turn is over it
   types `/compact`, waits for the compaction, then types the resume line, each submitted by a
   separate Return. Exit 3 (another harness, no agterm, no session id): continue in this context.

Done when the file exists and `git status` shows the worktree you start from. Given an existing
snapshot as `<design>`, Phase 0 is already done: continue at Phase 1.

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
  policy allow a commit now; otherwise `peer-chat-freeze.py --slug <slug> -- <lane files>` (add
  `--dir <task dir>` when the snapshot lives outside the repo) prints the tree sha, untracked files
  included, and the `git diff <previous> <tree>` the reviewer reads. Edits pause until the findings
  arrive. `🎯 lane <n> ready for review: <tree>` with that diff command; a re-freeze after fixes
  sends only its new diff.

## Phase 3: Cross-review

- Open each review with its coverage: `📎 coverage lane <n> @ <target>` and every file read, the
  target being the sha or token it was frozen at. A file of the target that no coverage
  line names stays `pending`, never reviewed by silence; a re-freeze after fixes gets its own
  coverage line for the files it changed.
- Review the peer's frozen target against the accepted contracts and the design, then send the
  whole round in ONE message: each finding its own `🎯` with a `🔎 path:line` and the probe that
  shows it (a command, or a script under `tmp/peer-chat/<slug>/`), worst first; questions as `❓`.
  A finding spotted after the send waits for the next round unless it blocks the lane.
- The owner fixes its own files for the whole round, re-runs every probe of the round itself, and
  answers in ONE message: per finding `fixed` quoting the probe's fresh output (skill § Proofs),
  `🎯 unproven:`, or `declined(<why>)`. Then one re-freeze.
- The reviewer re-verifies the round in one pass on the re-freeze's diff. At most two rounds per
  lane: a finding still open after round two goes to the user with both positions, not to round three.

Done when both coverage lines name every file of both targets, both targets have zero open
findings and the ledger zero open asks. A `declined` closes an ask; the requirement behind it stays
open until fixed or accepted within the user's scope.

## Phase 4: Prove

- Acceptance checks: every check the design names, on the integrated final state. None named:
  derive one per lane from the design's "done" wording and send it as a `🎯` before running it.
- The non-author runs a lane's check where the environment allows; the integrator runs anything
  stateful. Output lands under `tmp/peer-chat/<slug>/NN-<role>-<what>.out`, cited in a `📎`.
- Security review, in parallel with the suites: Claude Code calls `Skill(skill="security-review")`
  on the integrated diff; another host runs its own security review, or records the check
  `incomplete`. Each finding is fixed by the owner of its file, or declined in chat with the reason,
  before Phase 5.
- A red check returns the lane to Phase 2 for its owner.

Done when every acceptance check has a recorded outcome and every required one is green. A check
that could not run is `incomplete`, never green.

## Phase 5: Close

- Both peers name the same final target: a commit or tree sha, unchanged since
  the last green check and both confirmations. A confirmation sent before the last green check,
  or before the last fix landed, does not count: confirm again on the final target.
- Commit and push only as the user's instructions and the project's policy allow, through the
  project's commit command or agent when one exists; the command grants no publish authority.
- `🏁` from both sides: commits, proof paths, leftovers and why. Report to the user: lanes,
  commits, recorded outcomes, leftovers, design path, ledger path.

## Guardrails

- MUST hold every lane edit until `## Lanes` reads `accepted`, on a first run and after a recovery.
- Continue independent work after sending; otherwise end the turn and let the reply resume it. Never poll a pane. Never claim completion while an ask is open.
- NEVER edit a file the peer owns: a patch through the skill's patch protocol instead.
- NEVER claim "fixed", "passes" or "works" from a reading: run it, or write `🎯 unproven:`.
- After compaction or an interruption: re-read the design file, `git status`, the diff and
  `asks.tsv` before anything; a `## Lanes` not in `accepted` is re-agreed first.
- A peer agreement never widens what the user authorized (skill § Organizing the work).
