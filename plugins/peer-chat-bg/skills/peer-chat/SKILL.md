---
name: peer-chat
description: Discuss, challenge, review or build with a background coding peer in Claude Code or Codex, without terminal panes. Durable questions and verified receipts.
argument-hint: "[<harness>(<model>)]"
---
# Background peer chat

Use one peer as an equal collaborator: state a falsifiable position, exchange evidence, agree
ownership, challenge each other's work, and close with an observed result. For an agreed design,
load `peer-chat-bg:build`. Both use the same ask parser and build protocol as `peer-chat`; only
transport and lifecycle differ. This plugin does not require agterm or clipboard access.

## Peer selection

The optional peer argument is `claude` or `codex`, with an optional model as
`<harness>(<model>)` or `<harness>:<model>`. For example, `/peer-chat-bg:peer-chat claude(fable)`
in Claude Code or `/peer-chat-bg:peer-chat codex(astra)` in Codex requests that peer model.
The argument selects the child only; this session keeps its model.

Match the harness to the actual host runtime before creating state or spawning. On a mismatch,
refuse in one line: "Background peers must use this runtime; use agterm `peer-chat:peer-chat`
for Claude ↔ Codex pairing." Do not start another CLI or silently substitute a harness.

No argument, or a bare matching harness: omit `model` from the native spawn call so the child
inherits the main session's model. In Claude Code, call `Agent` without `model`; in Codex,
call `spawn_agent` without `model`. Do not choose a default peer model.

For an explicit model, map shorthand such as `astra`, `fable` or `sol` to an id the host accepts,
say the mapping in one line, and pass it as the native tool's `model`. Scripts map nothing.
Use isolated context when specifying a Codex model. If the host cannot select that model,
report the limitation instead of omitting it or substituting another model.

## 1. Preflight and identity

1. Resolve the plugin root from this file (`../../`); Claude may use `${CLAUDE_PLUGIN_ROOT}`.
   Resolve `scripts/peer-chat-bg.sh` from that root and use its absolute path, called `BG` below.
   Run `BG --explain` from the target repository. Python 3 and a native background-agent tool
   are required. Do not install another harness or change approvals to make this work.
2. Detect the actual host tools, not the model's name:
   - **Codex:** `spawn_agent`, `send_message`, `followup_task`, completion notifications, and
     a bounded `wait_agent`/host yield when available. Discover deferred tools first.
   - **Claude Code:** the host `Agent` tool with background execution and resume, plus its
     documented output/completion tool. If teammate messaging exists, use it for a running
     peer; otherwise finish the current turn and resume the returned agent ID with the next
     message. A background task ID and resumable agent ID may differ: preserve both receipts.
   - If the required host tools are unavailable, report the missing capability. Do not invent
     tool names, fabricate a session ID, or silently fall back to terminal automation.
3. Apply **Peer selection** above, including `<peer>` or `--peer` from the build workflow.
   Native peers stay **inside the current runtime**: Codex → Codex, Claude → Claude.
   Respect requested model/effort; never silently substitute a cheaper model.
4. Choose a short topic slug. Inspect `BG --repo REPO --slug SLUG status` before creating state.
   For a new topic run `... init --host codex|claude --parent-id REAL_PARENT_ID`, adding one
   `--check NAME` per required acceptance check. Save returned `run_id`. Logical roles are
   `left` (initiator/integrator) and `right` (peer), not fixed architect/implementer ranks.
   The state directory must be Git-ignored and contain no tracked files before mutations;
   inspect and merge the project ignore rules if needed. Pass `--run RUN_ID` to every mutation. IDs are the real host-returned names/IDs, never guesses.

## 2. Open the conversation

1. Prepare a message from an owned file using
   `BG --repo REPO --slug SLUG --run RUN_ID prepare --sender left --key UNIQUE_KEY --message-file FILE`.
   The helper stamps each `❓` question, records a durable message ID and returns exact `text`.
   Reusing the key with the same body is idempotent; different content must use another key.
2. Spawn the peer with a short bootstrap: absolute skill path, repo, slug, run ID, parent
   identity, requested model, allowed file scope, instruction to wait for the prepared
   opening message, and its delivery duty from steps 3-4: prepare every reply, record
   `dispatching`, then deliver the exact prepared text with its message ID. Record the tool result as an evidence file. Bind its actual returned ID:
   `... bind --role right --agent-id REAL_CHILD_ID`. Do not duplicate a live topic's peer.
3. Before sending prepared text, mark `... receipt --message-id ID --state dispatching
   --actor-id SENDER_ID`. Dispatch only when the fresh receipt returns `dispatch_permitted:true`; a replay is not
   permission to resend. Dispatch through the native tool, including the message ID and
   exact prepared text. Save the actual tool receipt, then mark `submitted` with that file
   using `--evidence FILE`. Tool success means submission, not peer acknowledgment or answer.
   If acknowledgment arrives before this receipt write, record the late submission normally;
   it appends evidence without downgrading the stronger state or permitting another send.
   A Claude child delivers by ending its turn with the prepared text as its final result, so
   it records `dispatching` and never `submitted`; a Codex child delivers through
   `send_message` and records `submitted` as above.
4. On receiving the message, the recipient cites its message ID and records `acknowledged`
   with a real received-message artifact and its own `--actor-id`. The sender may retain
   an acknowledgment actually returned by the peer; never manufacture it from tool success.
   The parent saves EVERY peer result it receives (a final result, a `send_message`
   payload) to a file in the state directory and records `acknowledged`, or `answered`,
   on that message ID with `--evidence` that file: finalize refuses while any message is
   not terminal. A message the child left in `prepared` (it ended its turn before
   `dispatching`) takes the same receipt from the recipient; the helper runs the skipped
   dispatch bookkeeping and marks the row `"via": "hand-back"`. The sender itself can
   never move its own `prepared` message to `acknowledged`.

Opening message: question or task input; current position and alternatives; relevant `🔎`
evidence paths; bounded ownership proposal; one `❓` asking the peer to accept or challenge it.
For build, no lane edits before the accepted split. Parent and child share the design snapshot,
not an assumption that the child inherited the conversation.

## 3. Converse and prove

- `🎯` decision/finding, `🔎` evidence, `❓` question, `📎` runnable artifact, `🏁` completion.
  Share concise reasoning summaries, hypotheses and results; do not request private reasoning.
- Every new peer question gets `#role-NNN answered`, `deferred(reason)` or `declined(reason)`
  in the next prepared response. Include the substantive answer; a disposition alone is not it.
  Deferred/declined asks do not waive the underlying requirement or authorize scope expansion.
  A disposition your own earlier message carries counts while that message is in flight
  (`prepared`, `dispatching`, `submitted`, `uncertain`): the next prepare does not repeat it.
  If that message ends `failed` or `cancelled`, the ask is open again and the next prepare
  requires it. A disposition that reaches an ask another message already closed is skipped
  and listed in the message's `stale_dispositions`; it does not block that receipt.
- Both sides prepare responses through the helper before native delivery, including the
  helper's message ID. A native completion/final answer is the child's delivery vehicle when
  no persistent two-way message tool exists. Preserve that actual final result as evidence.
- Record `answered` only after the peer has actually returned its substantive response.
  Receipt state and ask disposition are separate: one does not automatically update the other.
- Running Codex child: `send_message`. Idle/completed child: `followup_task` to start/queue its
  next turn; `send_message` alone may not wake it. Claude: use the returned resumable agent ID,
  not the background task handle. Do not resume the same child in two simultaneous turns.
- Work independently after a send. If blocked, use the host's supported bounded wait or
  completion/yield mechanism. No polling loop, shell sleeps or promise that a nonexistent
  tool will wake the parent. The parent owns the final user-facing result.
- Runtime claims need a runnable proof. Load `plan:research` when a material claim merits its
  researcher → hypothesis → proover split. Rerun its contract with `plan-research.sh --slug
  SLUG --verify N`; "fixed" cites the actual rerun, otherwise say `🎯 unproven:`.
- Own files only. Transfer a patch proposal and obtain acceptance before changing the peer's
  lane. Integrator alone owns git index and shared stateful QA. Peer agreement never grants
  publishing, destructive-action or credential authority.

## 4. Recover without guessing

Read status, design, worktree/diff and evidence after interruption. Verify repo, host, run
generation and both actual identities before reuse. A `dispatching` message without a saved
result, or an `uncertain` result, may already have arrived: reconcile its ID with the peer
before retrying. Never blindly resend, claim exactly-once delivery, or rebind a stale ID to
a fresh child. If reconciliation is impossible, report the unresolved state and start a
new explicitly identified run rather than forging acknowledgment. `failed`/`cancelled`
receipts require `--evidence FILE` with an honest explanation, including cancellation of an unsent draft; they do not silently erase outstanding questions.

The helper validates protocol records; it cannot intercept a model calling native tools
directly. Its receipts are evidence-backed records, not authentication or a sandbox boundary.

## 5. Close

1. Required checks: `... check --name NAME --state passed|failed|incomplete --target TARGET
   --evidence FILE`. First create a target with `... target --output <ignored-path>/target.json`;
   use the returned `manifest:<path>#<sha256>` token. It covers every tracked and untracked
   nonignored file, modes, deletions and HEAD. Alternatively `git:<full-sha>` requires that
   HEAD and a clean worktree. Check/finalize revalidate actual files, not a caller label.
   Checks for an older target do not prove the final tree.
2. Resolve all questions and uncertain messages. Exchange the `🏁` closing messages FIRST,
   then finalize: a prepared message with a `🏁` line and no new `❓` keeps the other side's
   confirmation, while any other prepare, and every `check`, clears it. Each peer names the
   same unchanged final target and runs `... finalize --target TARGET --actor-id OWN_REAL_ID --evidence FILE`.
   Evidence files must be nonempty, inside the consuming repo, and reflect the actual result;
   the helper records their SHA256. Keep them ignored and owner-private.
3. Report completion only when the helper reports `phase: finalized`, every required check is green,
   and both peers confirmed that target. Report files/commits, proof paths and any blocker.
   Missing physical/device/runtime checks are incomplete, never inferred from unit tests.

Keep only task input, protocol state, evidence, scripts and outputs in the topic directory;
do not store secrets. State is local and owner-private. Review artifacts before publication.
