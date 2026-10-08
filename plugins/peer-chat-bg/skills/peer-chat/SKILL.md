---
name: peer-chat
description: Discuss, challenge, review or build with a background coding peer in Claude Code or Codex, without terminal panes. Durable questions and verified receipts.
---
# Background peer chat

Use one peer as an equal collaborator: state a falsifiable position, exchange evidence, agree
ownership, challenge each other's work, and close with an observed result. For an agreed design,
load `peer-chat-bg:build`. Both use the same ask parser and build protocol as `peer-chat`; only
transport and lifecycle differ. This plugin does not require agterm or clipboard access.

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
3. Native peers stay **inside the current runtime**: Codex → Codex, Claude → Claude. `--peer`
   in the build workflow requests an available host/model, not a cross-runtime bridge. For
   Claude ↔ Codex pairing use an explicitly available bridge or original agterm `peer-chat`;
   this plugin does not claim to provide that bridge. Respect requested model/effort; never
   silently substitute a cheaper model. Isolate context when specifying a Codex model.
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
   identity, requested model, allowed file scope and instruction to wait for the prepared
   opening message. Record the tool result as an evidence file. Bind its actual returned ID:
   `... bind --role right --agent-id REAL_CHILD_ID`. Do not duplicate a live topic's peer.
3. Before sending prepared text, mark `... receipt --message-id ID --state dispatching
   --actor-id SENDER_ID`. Dispatch only when the fresh receipt returns `dispatch_permitted:true`; a replay is not
   permission to resend. Dispatch through the native tool, including the message ID and
   exact prepared text. Save the actual tool receipt, then mark `submitted` with that file
   using `--evidence FILE`. Tool success means submission, not peer acknowledgment or answer.
   If acknowledgment arrives before this receipt write, record the late submission normally;
   it appends evidence without downgrading the stronger state or permitting another send.
4. On receiving the message, the recipient cites its message ID and records `acknowledged`
   with a real received-message artifact and its own `--actor-id`. The sender may retain
   an acknowledgment actually returned by the peer; never manufacture it from tool success.

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
2. Resolve all questions and uncertain messages. Each peer names the same unchanged final
   target and runs `... finalize --target TARGET --actor-id OWN_REAL_ID --evidence FILE`.
   Evidence files must be nonempty, inside the consuming repo, and reflect the actual result;
   the helper records their SHA256. Keep them ignored and owner-private.
3. Report completion only when the helper reports `phase: finalized`, every required check is green,
   and both peers confirmed that target. Report files/commits, proof paths and any blocker.
   Missing physical/device/runtime checks are incomplete, never inferred from unit tests.

Keep only task input, protocol state, evidence, scripts and outputs in the topic directory;
do not store secrets. State is local and owner-private. Review artifacts before publication.
