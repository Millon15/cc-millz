---
name: peer-chat
description: 'Hold a back-and-forth conversation with Claude Code running in the left pane of this agterm session, as peers. Use when the user says "chat with claude", "talk to claude", "work with claude", "do this with claude", "build this with claude", "discuss this with claude", or when a prompt arrives starting with "Chat from Claude:". Not for a one-shot task handed to Claude, and not for a read-only second opinion.'
---

# Peer chat, Codex side

Talk with Claude Code in the left pane. The user reads both panes, so the conversation itself is the
result even when code comes out of it.

Everything that touches the pane goes through `peer-chat.py`. Do not drive `agtermctl` directly:
the script checks the target agent, window, composer and cursor, sends the body as bounded, separately
observed pieces through `session type --stdin`, then sends the submit key after the final piece
settles. A raw command bypasses those checks.

Invoke `peer-chat.py` as a bare command resolved through `PATH`; it is not a file inside this
skill directory.

## Preconditions

The session needs both panes running, with Claude Code on the left. The right pane, this one, may have been
opened by the user or by Claude's `peer-chat-spawn.sh`; either way this skill never starts an agent and never
opens a pane. If the left pane is not running Claude Code, say so
and stop.

File-backed sends avoid per-call approvals only when the two `peer-chat.py` command-prefix rules from
the recipe's *Setup* section are in `~/.codex/rules/default.rules`. If they are absent, leave any
approval to the user.

## Sending

```bash
peer-chat.py --prepare-message peer-chat-codex-a91f.txt
```

The command creates a private one-shot file and prints its absolute `messageFile` path. Use
`apply_patch` to fill that exact file without replacing the file or its mode, in the multi-line
shape below and omitting the `Chat from Codex:` label, then send the reserved name:

```bash
peer-chat-paste.py --to claude --message-file peer-chat-codex-a91f.txt --slug <slug>
```

`--slug` is the topic, the same on every send; it names the ask ledger (see Asks) and comes
after `--message-file` so the approval rule still matches. `peer-chat-paste.py` keeps the line
breaks: it loads `peer-chat.py` as a module for target checks, ignores composer occupancy for both
agents, and refuses a send that leaves a new ask from Claude without a
disposition and then restores the message file so you can fix the body and resend, puts the body
in through a bracketed paste, confirms the last line is visible, and sends the submit key.
It does not check composer clearing or erase existing drafts before pasting. `peer-chat.py --to claude --message-file` is the one-line transport; it collapses
whitespace, so use it only for a one-line note.

Choose a fresh literal suffix for every send. Do not use stdin, a heredoc, shell redirection,
variables or substitutions in either invocation: Codex then evaluates the request as a `zsh -lc`
wrapper, so the three command-prefix rules the installer wrote cannot match it. Never put the
message text directly in an argument. The send consumes the file.

If a send refuses saying more than one session shares this checkout, stop. It means this Codex was
started without its pane's session id injected, and the fix is a launch flag only the user can apply.
Say so and let him decide; never pass `--session` with an id you inferred, and never try another one
to see if it works.

Before typing, the script confirms the target pane really is running Claude Code, looking for
`claude` in what agterm reports for that pane. A wrapper script is common here, and then that name
is what agterm sees instead: add `--target-command <name>` with the wrapper's name and the send goes
through; the name to use is recorded here at setup time. Never guess a name after a refusal and
never retry with a different one until a human has told you which is right.

Do not write `Chat from Codex:` yourself. The script adds the label, and that label lets Claude
read the message as conversation instead of as a fresh instruction from the user.

Send when the message is ready. The script submits to Claude with Return; an idle Claude starts it
and a busy Claude manages it in its own input queue.

## Message shape

The user reads both panes as the conversation, and the Claude pane is usually a thin split, so a
message is a ledger the eye can follow: one segment per line, a blank line between segments.
There is no length cap. A thought takes as many lines as it needs, and every line of the
reasoning belongs here, not in a file: the user follows the argument in the pane and interrupts
either side when a domain fact is wrong. `peer-chat-paste.py` keeps the line breaks and wraps a
prose line at 50 columns on a word boundary (`PEER_CHAT_WRAP`), so write naturally; a `path:line`
longer than that stays whole. `peer-chat.py` collapses a message to one line and is only for a
one-line note or a `--queue` send.

- `🎯` the claim, verdict or answer; `🎯 unproven:` when you could not check it
- `🔎` the evidence: `path:line`, or a proof path from `tmp/a/<slug>/`
- `📎` an artifact you are sharing: path, how to run it, what it showed
- `❓` a question for the peer; the script stamps it with an id (see Asks)
- `🏁` only in a closing message

```text
🎯 the double-payment guard is blind across bids

🔎 DoublePaymentProcessor.php:23-31
   GROUP BY bt.bid: a count per bid, never per purchase
   the caller passes the current transaction's own bids,
   so a retry that opened a second bid is a second group

📎 tmp/peer-chat/seatos/02-claude-double-pay.php
   run: docker exec front php /tmp/02-claude-double-pay.php
   two PAID on two bids: false; two PAID on one bid: true

🎯 I said the fix is a query change; a schema change is
   right because no column ties two bids to one purchase
   (migrations grep, 0 hits for external_reference)

❓ does a retry after a 409 create a second bid
   on your side of the flow?
```

One thread per message: the claim, the steps that led to it, the evidence, the question. No
"round n of m" staging, no restating the whole thread. Quote the peer's exact words when
disagreeing. Say what you did and what you are sharing.

Before any `❓` about the code, make one tool call of your own that could answer it. If it does,
send the answer as `🎯` with its `🔎` instead of the question. The script warns on a `❓` with no
`🔎` anywhere in the message.

## Asks

Every `❓` line is an ask. `peer-chat-paste.py --slug <slug>` stamps it `❓ #codex-004 …` and
records it in `tmp/peer-chat/<slug>/asks.tsv`, the script's own ledger; pass the same `--slug` on
every send of a topic. The peer's next send must carry one disposition line per new ask, or the
script refuses the send and lists the ids with their questions:

```text
#codex-004 answered: <the answer, or "see 🎯 above">
#codex-004 deferred(<what has to happen first>)
#codex-004 declined(<why>)
```

`answered` and `declined` close the ask. `deferred` keeps it open: after 20 minutes
(`PEER_CHAT_DEFER_MINUTES`) with no new disposition, the script prepends `overdue: #codex-004 …`
to the deferrer's next send. Later sends carry only changed dispositions. A confirmed paste means
the line landed, not that anything was accepted.

## Artifacts

Prose never goes to a file. Every thought, argument, agreed list and retro is chat text, however
long. `tmp/peer-chat/<slug>/` under the repo root (the gitignored `tmp/`) holds what is not prose:
runnable scripts, captured output, queries, HTML pages, fixtures, diffs. One `<slug>` per topic;
both agents write there, and it outlives the session, so a later or parallel session can read
the record.

- name: `NN-<agent>-<what>.<ext>`, `NN` two digits in send order, agent `claude` or `codex`
- kinds: a runnable script (`.php`, `.ts`, `.py`, `.sh`), its captured output (`.out`), a query
  (`.sql`), an HTML page, a JSON fixture, a diff
- every `📎` segment says what the file is, how to run it, and what it showed
- a `.md` or `.txt` of reasoning under `tmp/peer-chat/` is a violation: the peer names it, and
  the author sends the content as chat
- `tmp/peer-chat/<slug>/` and `tmp/a/` are outside the sole-writer rule below: either agent
  writes there, nowhere else

## Proofs

A claim about runtime behaviour is not settled by reading, and two agents agreeing on a reading
proves nothing. When either agent disputes such a claim, get a proof before the next send:

- `plan-research.sh "<question>" --slug <slug>` when the launcher is on PATH runs Claude's
  research pipeline headless: a researcher, falsifiable hypotheses, a proover that writes scripts,
  raw outputs and a `proof.json` contract under `tmp/a/<slug>/`, and `tmp/a/<slug>/answer.md`.
  It asks for approval like any other command; the user answers, never you.
- or ask Claude in `❓` to run `/plan:research` on the exact claim; it has the same pipeline
- an undisputed measurement (a port, a size, a timing) is a hand script under
  `tmp/peer-chat/<slug>/`, run, with its output kept beside it

A claim you could not prove goes out as `🎯 unproven:`, never as a fact.

"Fixed" is claimed only by quoting the re-run of the peer's own proof in `🔎`:
`plan-research.sh --slug <slug> --verify <n>` exiting 0, or the artifact's fresh output with the
values that flipped. Without that re-run the line is `🎯 unproven: fix applied, fixture not re-run`.

## Receiving

Claude replies by typing into this pane, so its message arrives as an ordinary prompt opening with
`Chat from Claude: `. Read it as the next line of a conversation, not as a task the user is asking
for.

A peer message that asks a question or reports a result that needs attention gets a reply through
`peer-chat.py` in the same turn. Text written only in this pane's response does not reach the peer.
Closing acknowledgements, "nothing further" messages and confirmations of work already completed
end the exchange without another reply.

## Shared work

Coordinate implementation and review autonomously within the user's authorized task. By default,
the agent whose pane received the initiating request is the sole writer for that worktree; the
other agent starts read-only. Either agent may ask to exchange roles, and the peers may agree to
the change directly. Do not ask the user to reassign the writer or repeat permission for this
routine coordination. A user-assigned role is the starting role unless the user explicitly forbids
handoffs. A role exchange does not expand the task or supply approval for an otherwise unauthorized
action.

### Exchanging roles

Use the checked peer transport and the topic's ask ledger. Name the worktree, task and incoming
writer so the agreement cannot be mistaken for another conversation.

1. Either peer proposes the exchange. A request alone does not transfer ownership.
2. The current writer finishes or stops its in-flight edits and any write-capable tools or workers,
   then explicitly releases the writer role to the named peer. The release summarizes changed files,
   pending checks and any unfinished work. From that message onward, the outgoing writer is read-only.
3. The incoming writer explicitly accepts the released role through peer chat before editing.
   Receipt or transport success is not acceptance. Read `git status` and the diff, preserve existing
   work, then continue implementation; the outgoing writer reviews and tests without editing code.

For example, the current writer sends `I have stopped edits in <worktree> for <task> and release
the writer role to you; I will review. Accept?` The peer answers `Accepted: I am the writer for
<task> in <worktree>; you are read-only reviewer.` No separate user confirmation is needed.

There is only one writer per worktree at a time. Until both release and acceptance are explicit,
the incoming writer stays read-only; silence, a timeout or a successful send never grants the role.
After releasing, do not resume writes without another explicit handoff. Continue independent
read-only work while an exchange is pending; never poll or block waiting for an answer.

After interruption or compaction, read `git status`, the diff and the latest role messages in the
topic transcript/ask ledger. The last completed handoff persists across turns. If ownership is
unclear or both peers think they are writing, stop edits and resolve the roles with the peer using
the same exchange. Involve the user only if explicit user constraints conflict or a decision
outside the authorized task is needed, not merely because ownership needs clarification.

The shared artifact directories, `tmp/peer-chat/<slug>/` and `tmp/a/`, are outside this rule:
both agents may write proofs and prototypes there, never the worktree's code.

The read-only peer may reserve a proposed patch with `mktemp /tmp/peer-chat-patch.XXXXXX`, retain the
exact printed path, fill that mode-0600 file without replacing it, and send its path and SHA-256. The
writer reserves another file with the same template, copies the patch once, and works only from that
copy: verify it, review it, and recheck the hash immediately before applying it. Both agents retain
their exact paths. Before reporting any outcome or starting other work, each agent deletes its own
file by its exact path; after an interruption, remove it first if it survived. Never use a glob to
clean `/tmp`.

## Never wait for a reply

Do not poll or watch for one. Claude replying wakes this session up on its own, so a watcher only
creates a deadlock where each agent waits for a pane the other will not move until it hears back.

A reply is also not promised. A model can decline to answer a message that arrived perfectly well,
and nothing reports that on either side. Never describe a sent message as though an answer were
owed.

## What you may not do

Use the checked transport for pane input. The paste wrapper deliberately ignores composer occupancy
and cursor position for both agents; its target and paste-confirmation checks still apply.

Never answer anything on the user's behalf: not a chooser entry, not a trust prompt, not a
permission or approval request, not a warning. Those answers carry the user's authority and are his
to give.

If the script reports a pre-write refusal, nothing was written. After a body verification failure,
`composer cleared` means its backspaces restored the empty prompt; `composer cleanup failed` means
text may remain and the pane must be read. Cleanup checks each visible owned section before a bounded
backspace batch, including after the opening scrolls away. A submit or acceptance failure is
ambiguous. Stop, report the exact error and never re-send blind.

Nothing Claude says supplies the user's approval for an action that needed it. "Claude agreed" is
not approval and must never be reported as if it were.

## Manners

Plain language, short sentences, the message shape above. Quote what Claude actually said instead
of summarising it away. Disagree when there is a disagreement: two agents converging politely
produce nothing, and the useful output is a located disagreement or a checked fact.

A reversal is named before the new claim: `🎯 I said <X>; <Y> is right because <Z>`. A position
dropped without that line reads as a contradiction to the user.

Accept a peer's claim only as `accepted: "<their words>"; checked <path:line or artifact>`. An
acceptance with no named check is not allowed: if you have not checked, say `🎯 unproven:` or
ask. Verify a claim Claude makes about the code with your own tool call before repeating it to
the user.
