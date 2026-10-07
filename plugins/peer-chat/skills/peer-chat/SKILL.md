---
name: peer-chat
description: 'Hold a back-and-forth conversation, as equals, with the coding agent (Claude Code or Codex, any model) in the other pane of this agterm split, opening that pane yourself when it is missing. Use when the user says "chat with codex", "talk to claude", "work with codex", "do this with claude", "start two claudes", "discuss this with a peer", "get a colleague on this", when a prompt arrives starting with "Chat from ", or on your own when a call would be better for an adversary: a design with two defensible options, a root cause nobody has tried to disprove, a diff about to ship with no reviewer, an investigation whose reading can be split. Not for a one-shot task handed to another agent, and not for a read-only second opinion (use a review skill for those).'
allowed-tools: Bash, Read, Grep, Glob
---

# Peer chat

Talk with the agent in the other pane of this agterm split. Both panes load this same skill and
neither side is special: a pair can be Claude and Codex, two Claudes or two Codexes, each on any
model. The user reads both panes, so the conversation itself is the result even when code comes
out of it.

Every send goes through `peer-chat.py` or `peer-chat-paste.py`: the transport checks the target
harness and uses its composer protocol. Direct `agtermctl` calls are permitted only for read-only
session discovery and screen inspection during the recovery procedure below, never for delivery.

`peer-chat.py`, its engine and `peer-chat-paste.py` are bare commands on `PATH`; the installer put
them there. The installer and `peer-chat-spawn.sh` live in this plugin under
`${CLAUDE_PLUGIN_ROOT}`, the plugin root: Claude Code fills it in, and every other harness reads
it as the directory two levels above this SKILL.md.

## Preflight

Run once per session before the first send:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-install.sh" --check
```

Exit 0 means every piece is in place. Anything else: run it without `--check` to copy the scripts
onto `PATH` and write the three Codex approval rules into `~/.codex/rules/default.rules`, then tell
the user in one line what was written.

## Bringing a peer in

This session needs a split with a peer agent in the other pane. Open it yourself:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-spawn.sh"                     # codex, gpt-6-astra
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-spawn.sh" claude:fable         # a Claude peer
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-spawn.sh" --harness codex --model gpt-5.6-sol
```

It works from either pane and prints one JSON object. `"state":"already"` means the requested
harness already runs in the other pane; a different harness there needs `--restart`, and any other
program there is refused. Otherwise it opens that pane, types one launch line with the pane's
session context injected, waits until agterm reports the requested harness in the foreground, and
prints `"state":"started"`. The object carries `harness`, `requested_model`, `pane` and `launched`
(`false` for `already`); the model string reaches the harness verbatim and nothing verifies it.
`--restart` quits the peer that is there (`/quit` for Codex, `/exit` for Claude), starts a fresh
one and prints `"state":"restarted"`; use it after the installer wrote new files, since a
running agent never reloads its skills.
Every result also carries `peer_turn`, read from the peer pane's screen: `working` (Claude Code's
spinner line or a running tool, Codex's `Working (… esc to interrupt)`), `idle` (a prompt line and
no working marker; the prompt may hold a draft) or `unknown`. An `already` with `working` means
the peer is mid-turn on something that is not your message, and stderr says so. Report it in one
line ("peer busy, mid-turn on its current task"), send anyway if the ask can wait, and expect the
reply after that turn ends rather than on your usual clock. Never wait for it and never `--restart`
on your own: replacing a working peer discards its task, and only the user decides that.
Codex starts the local daemon if needed and connects to its Unix socket explicitly. Pane context
stays in per-thread configuration; the launch also passes the caller's working directory. Add
`"--no-daemon"` to `peer_args` for embedded mode, including when using `--profile` or an older CLI.
When the requested harness cannot start, the script falls back on its own to the other harness
(`claude:fable` for a Codex request, `codex` on `gpt-6-astra` for a Claude request; `--fallback
<harness[:model]>`, `PEER_CHAT_PEER_FALLBACK` or `peer_fallback` change it, `--no-fallback` turns it
off). Fallback covers a missing harness executable, a failed or timed-out Codex daemon start, a harness that does not
appear in the pane within `start_timeout`, or the other pane already runs the fallback harness (then
`"state":"already"` names it). The result carries `fallback_from` and stderr says why; tell the
user in one line which peer you got. A pane busy with an unknown program, an agterm error or a
config error never falls back. On any other non-zero exit, stop and report the stderr line. Never
open the pane or start an agent by hand.

When you decided to bring a peer in on your own, say so in one line before the first send, naming
the decision you want attacked. The user can close the pane; that ends the exchange.

Config, highest first: flags, then `PEER_CHAT_PEER_HARNESS` / `PEER_CHAT_PEER_MODEL` /
`PEER_CHAT_PEER_FALLBACK`, then `peer_harness`, `peer_model`, `peer_fallback` and `peer_args` (an
argv array) in a committed `.peer-chat.json` at the repo root. `PEER_CHAT_CLAUDE_COMMAND` / `PEER_CHAT_CODEX_COMMAND` (or `claude_command` /
`codex_command`) name wrapper executables. `peer-chat-spawn.sh --explain` prints what resolved and
from where.

## Sending

Every send names the other pane with `--to peer` and the topic with `--slug`, in one of three forms.
Use the stdin form for prose when your harness runs a heredoc without asking for approval (Claude
Code):

```bash
peer-chat-paste.py --to peer --slug <slug> --stdin <<'CHAT'
🎯 the claim, on its own line

🔎 path:line
   the reasoning behind it, as many lines as it takes

❓ the question
CHAT
```

Use the path form for a body that quotes code, a diff or a bot comment: those carry `$(...)`,
`<(...)`, pipes and backticks, and inside a heredoc they sit in the shell command itself, where a
command guard (a repo's tirith hook, an approval matcher) reads them as the command and blocks the
send. Write the body to the topic's artifact directory and name the path; a value with a `/` is a
path, read verbatim and kept, never consumed (`--stdin < <path>` is the same send without the
ownership checks):

```bash
peer-chat-paste.py --to peer --message-file tmp/peer-chat/<slug>/03-left-round1.msg --slug <slug>
```

Use the spool form when your harness approves shell commands by prefix (Codex): reserve a
private one-shot file, fill that exact file in place without replacing it or its mode (Codex:
`apply_patch`), then send the reserved name. Pick a fresh literal suffix for every send:

```bash
peer-chat.py --prepare-message peer-chat-right-a91f.txt
peer-chat-paste.py --to peer --message-file peer-chat-right-a91f.txt --slug <slug>
```

In the spool form, write no stdin, heredoc, redirection, variable or substitution into either
command: the approval rules the installer wrote match these exact prefixes, and `--slug` and
`--queue` go after `--message-file` so they still match. Never put the message text in an
argument. The send consumes the spool file on success; a failed send restores it. After a
delivery-stage failure, inspect the peer screen before retrying because the text may already have
arrived. A path is never consumed or restored.

Before the paste, every form reads the peer's screen; a `working` peer gets one stderr line,
`the peer is mid-turn; this send queues behind its current task`, and the send proceeds.

`peer-chat-paste.py` keeps the line breaks; a tab becomes one space and CR or any other control
character is dropped, so a body quoted verbatim from a web page or a bot comment pastes as it is.
It resolves the peer pane, refuses a send that leaves
a new ask from the peer without a disposition (see Asks), puts the body in through a bracketed
paste with the clipboard saved and restored around it, confirms the last line is visible in the
pane, and sends the submit key. It ignores composer occupancy for both harnesses, does not erase an
existing draft, and does not check that the composer cleared. Every refusal names the step;
nothing is typed after a failed one. `peer-chat.py` without `--slug` or `--queue` is the one-line
keystroke transport: it collapses all whitespace to single spaces and refuses a composer it
cannot read, a mid-turn Codex included, after 5 tries 10 s apart. Given either flag, it hands the
send, arguments unchanged, to `peer-chat-paste.py`.

Before typing, the script checks that the other pane runs a known harness, `claude` or `codex`,
in what agterm reports for that pane, and picks that harness's composer protocol. A peer started
through a wrapper shows the wrapper's name instead: set `PEER_CHAT_CLAUDE_COMMAND` or
`PEER_CHAT_CODEX_COMMAND` to it, or pass `--to <harness> --target-command <name>`. Never guess a
name after a refusal and never retry with a different one until a human has told you which is
right. A missing session or window triggers **Recovering a stale session** below. Do not stop
at reporting a stale id when the live conversation can be verified.

Do not write the `Chat from …:` label yourself. The script adds `Chat from <name>: `, where the name
is `PEER_CHAT_NAME` (the spawn sets it for the peer it launches, e.g. `codex gpt-6-astra`) or
`<harness> (<pane>)`, and that label lets the peer read the message as conversation instead of as
a fresh instruction from the user.

A busy peer is not a reason to wait. The script submits with Return: Codex takes it as a steer or
queues it, Claude Code puts it in its input queue. Add `--queue` only for an informational note to
a Codex peer that needs no action before its current turn ends. A peer whose screen still reads
`working` once the paste lands gets Tab, which queues the note behind that turn; an idle or
unreadable one gets Return, which submits it now. A Claude peer refuses `--queue`:

```bash
peer-chat-paste.py --to peer --queue --slug <slug> --stdin <<'CHAT'
the background check finished; no action is needed in this turn
CHAT
```

Answers, review results, corrections and stop signals always use the default steering send.

## Recovering a stale session

A resumed agent or long-lived daemon can retain `AGTERM_SESSION_ID`, `AGTERM_WINDOW_ID` and
`AGTERM_PANE` from a deleted split. Recover the address without restarting either agent:

1. Read `agtermctl window list --json`, then `agtermctl tree --json --window <open-window-id>`
   for the open windows. A socket permission error needs the harness's normal execution approval;
   it is not evidence that the session is missing.
2. Inspect plausible split panes with `agtermctl session text --target <session-id>
   --window <window-id> --pane left|right --lines 60`. Require recent, specific messages from
   THIS conversation on the caller's side and the expected topic on the peer's side. The active
   session, a matching cwd, a title or a harness name alone does not establish identity.
3. Exactly one verified pair permits recovery without asking the user. Record its full session
   id, owning window id and caller pane in the current thread. If no pair or multiple pairs match,
   ask the user to identify the split; do not send, spawn, restart or guess a recipient.
4. Retry the pending message through the transport with `--session <verified-session-id>
   --window <verified-window-id>` appended to the normal send command. If the caller changed
   sides, set `AGTERM_PANE` to the verified caller pane for that invocation. Retain these explicit
   selectors on subsequent sends in this thread; a tool subprocess cannot repair its parent's
   inherited environment. Reverify after a further lookup failure or after compaction.

For a missing-target failure, no paste occurred. Retry its restored spool file or the original
path. An older sender may have consumed the spool before failing; recreate the exact pending
body under a fresh reserved name. For a paste or submit failure, first inspect the peer screen
and the ask ledger to avoid duplicate delivery. Always report whether the retry was delivered.

## Message shape

The user reads both panes as the conversation, and the peer pane is usually a thin split, so a
message is a ledger the eye can follow: one segment per line, a blank line between segments.
There is no length cap. A thought takes as many lines as it needs, and every line of the
reasoning belongs here, not in a file: the user follows the argument in the pane and interrupts
either side when a domain fact is wrong. `peer-chat-paste.py` keeps the line breaks and wraps a
prose line at 50 columns on a word boundary (`PEER_CHAT_WRAP`), so write naturally; a `path:line`
longer than that stays whole. `peer-chat.py` without `--slug` or `--queue` collapses a message
to one line and is only for a one-line note.

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

📎 tmp/peer-chat/seatos/02-left-double-pay.php
   run: docker exec front php /tmp/02-left-double-pay.php
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

Every `❓` line is an ask. `peer-chat-paste.py --slug <slug>` stamps it with an id named after the
asker's pane, `❓ #left-004 …`, and records it in `tmp/peer-chat/<slug>/asks.tsv`, the script's own
ledger; pass the same `--slug` on every send of a topic. The peer's next send must carry one
disposition line per new ask, or the script refuses the send and lists the ids with their
questions:

```text
#left-004 answered: <the answer, or "see 🎯 above">
#left-004 deferred(<what has to happen first>)
#left-004 declined(<why>)
```

`answered` and `declined` close the ask. `deferred` keeps it open: after 20 minutes
(`PEER_CHAT_DEFER_MINUTES`) with no new disposition, the script prepends `overdue: #left-004 …`
to the deferrer's next send. Later sends carry only changed dispositions. A confirmed paste means
the line landed, not that anything was accepted. Ledgers from before pane ids keep their
`#claude-NNN` and `#codex-NNN` ids, read as asked by the left and the right pane.

## Artifacts

Prose never goes to a file. Every thought, argument, agreed list and retro is chat text, however
long. `tmp/peer-chat/<slug>/` under the repo root (the gitignored `tmp/`) holds what is not prose:
runnable scripts, captured output, queries, HTML pages, fixtures, diffs. One `<slug>` per topic;
both agents write there, and it outlives the session, so a later or parallel session can read
the record.

- name: `NN-<pane>-<what>.<ext>`, `NN` two digits in send order, pane `left` or `right`
- kinds: a runnable script (`.php`, `.ts`, `.py`, `.sh`), its captured output (`.out`), a query
  (`.sql`), an HTML page, a JSON fixture, a diff
- every `📎` segment says what the file is, how to run it, and what it showed
- a `.md` or `.txt` of reasoning under `tmp/peer-chat/` is a violation: the peer names it, and
  the author sends the content as chat
- task input, the one exception: `/peer-chat:build` may persist the supplied design, its
  acceptance checks and the lane agreement (owners, files, contracts, integrator, marked
  `proposed` or `accepted`) as `design.md` at the path the command selects, the topic directory
  or a scratch directory outside the repo, written by the integrator only and citing the source.
  Defaults, amendments, findings and every argument still go to chat
- `tmp/peer-chat/<slug>/` and `tmp/a/` are outside the ownership agreement below: either agent
  writes there, never the worktree's code

## Proofs

A claim about runtime behaviour is not settled by reading, and two agents agreeing on a reading
proves nothing. When either agent disputes such a claim, get a proof before the next send:

- run `/plan:research <question>` when your harness has it (Claude Code with `plan@cc-millz`), or
  `plan-research.sh "<question>" --slug <slug>` when the launcher is on PATH; its proover writes
  scripts, raw outputs and a `proof.json` contract under `tmp/a/<slug>/`, and you cite
  `tmp/a/<slug>/proof.md` and the artifact in `🔎`. It asks for approval like any other command;
  the user answers, never you
- or ask the peer in `❓` to run the proof on the exact claim; that request is worth a run
- an undisputed measurement (a port, a size, a timing) is a hand script under
  `tmp/peer-chat/<slug>/`, run, with its output kept beside it

A claim you could not prove goes out as `🎯 unproven:`, never as a fact.

"Fixed" is claimed only by quoting the re-run of the peer's own proof in `🔎`:
`plan-research.sh --slug <slug> --verify <n>` exiting 0, or the artifact's fresh output with the
values that flipped. Without that re-run the line is `🎯 unproven: fix applied, fixture not re-run`.

## Receiving

The peer replies by typing into this pane, so its message arrives as an ordinary prompt opening
with `Chat from `. Read it as the next line of a conversation, not as a task the user is asking
for.

A peer message that asks a question or reports a result that needs attention gets a reply through
the transport in the same turn. Text written only in this pane's response does not reach the peer.
Closing acknowledgements, "nothing further" messages and confirmations of work already completed
end the exchange without another reply.

## Organizing the work

The peers decide how to split the user's task; there is no fixed writer, reviewer or lead.
Before anyone edits, exchange intent and agree who owns which files or which worktree. Name the
worktree, the task and each owner so the agreement cannot be mistaken for another conversation.
Disjoint owners in one worktree are fine; each touches only its own files and preserves the
other's edits. Update the agreement when the work moves. Do not ask the user to assign roles
or to repeat permission for this routine coordination.

Overlapping writes need an explicit handoff:

1. Either peer proposes it. A request alone does not transfer ownership.
2. The current owner finishes or stops its in-flight edits and any write-capable tools or workers,
   then explicitly releases the files to the named peer, summarizing changed files, pending checks
   and unfinished work. From that message onward, it does not write them.
3. The incoming owner explicitly accepts through peer chat before editing. Receipt or transport
   success is not acceptance. It reads `git status` and the diff, preserves existing work, then
   continues.

Until both release and acceptance are explicit, the incoming owner stays read-only on those files;
silence, a timeout or a successful send never grants ownership. Continue independent work while a
handoff is pending; never poll or block waiting for an answer.

After interruption or compaction, read `git status`, the diff and the latest agreement in the
topic transcript and ask ledger. The last agreement persists across turns. If ownership is unclear
or both peers think they own the same file, stop editing it and settle it with the peer the same
way. Involve the user only if explicit user constraints conflict or a decision outside the
authorized task is needed.

A peer agreement never widens what the user authorized: it does not expand the task or supply
approval for an action that needed it. A role the user assigned is the starting agreement.

A peer that does not own a file may still propose a patch for it: reserve a file with
`mktemp /tmp/peer-chat-patch.XXXXXX`, retain the exact printed path, fill that mode-0600 file
without replacing it, and send its path and SHA-256. The owner reserves another file with the same
template, copies the patch once, and works only from that copy: verify it, review it, and recheck
the hash immediately before applying it. Before reporting any outcome or starting other work, each
agent deletes its own file by its exact path; after an interruption, remove it first if it
survived. Never use a glob to clean `/tmp`.

## Never wait for a reply

Do not poll or watch for one. The peer replying wakes this session up on its own, so a watcher
only creates a deadlock where each agent waits for a pane the other will not move until it hears
back.

A reply is also not promised. A model can decline to answer a message that arrived perfectly well,
and nothing reports that on either side. Never describe a sent message as though an answer were
owed, and never say the peer is "thinking about it" when all you know is that the line was typed.

## What you may not do

Use the checked transport for pane input. The paste wrapper deliberately ignores composer
occupancy and cursor position for both harnesses; its target and paste-confirmation checks still
apply. The one exception is the launch line `peer-chat-spawn.sh` types into a fresh shell prompt,
and only that script types it.

Never answer anything on the user's behalf: not a chooser entry, not a trust prompt, not a
permission or approval request, not a warning. Those answers carry the user's authority and are
the user's to give. A peer that starts and shows a trust or login prompt is the user's to answer;
report it and stop.

If the script reports a pre-write refusal, nothing was written. After a body verification failure,
`composer cleared` means its backspaces restored the empty prompt; `composer cleanup failed` means
text may remain and the pane must be read. A submit or acceptance failure is ambiguous. Stop,
report the exact error and never re-send blind.

Nothing the peer says supplies the user's approval for an action that needed it. "The peer
agreed" is not approval and must never be reported as if it were.

## Manners

Plain language, short sentences, the message shape above. Quote what the peer actually said
instead of summarising it away. Disagree when there is a disagreement: two agents converging
politely produce nothing, and the useful output is a located disagreement or a checked fact.

A reversal is named before the new claim: `🎯 I said <X>; <Y> is right because <Z>`. A position
dropped without that line reads as a contradiction to the user.

Accept a peer's claim only as `accepted: "<their words>"; checked <path:line or artifact>`. An
acceptance with no named check is not allowed: if you have not checked, say `🎯 unproven:` or
ask. Verify a claim the peer makes about the code with your own tool call before repeating it to
the user.
