---
name: peer-chat
description: 'Hold a back-and-forth conversation, as equals, with the coding agent (Claude Code or Codex, any model) in the other pane of this agterm split, opening that pane yourself when it is missing. Use when the user says "chat with codex", "talk to claude", "work with codex", "do this with claude", "start two claudes", "discuss this with a peer", "get a colleague on this", when a prompt arrives starting with "Chat from ", or on your own when a call would be better for an adversary: a design with two defensible options, a root cause nobody has tried to disprove, a diff about to ship with no reviewer, an investigation whose reading can be split. Not for a one-shot task handed to another agent, and not for a read-only second opinion (use a review skill for those).'
argument-hint: "[<harness>(<model>)]"
allowed-tools: Bash, Read, Grep, Glob
---

# Peer chat

Talk with the agent in the other pane of this agterm split. Both panes load this same skill and
neither side is special: a pair can be Claude and Codex, two Claudes or two Codexes, each on any
model. The user reads both panes, so the conversation itself is the result even when code comes
out of it.

Every send goes through `peer-chat.py` or `peer-chat-paste.py`: the transport checks the target
harness and uses its composer protocol. Direct `agtermctl` calls are permitted only for read-only
session discovery and screen inspection during the recovery procedure below, and for the notice
in § A held send, never for delivery.

`peer-chat.py`, its engine, `peer-chat-paste.py` and `peer-chat-state.py` are bare commands on `PATH`; the installer put
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
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-spawn.sh"                     # the configured peer (default codex, own model config)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-spawn.sh" claude              # a Claude peer, model from its own config
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-spawn.sh" 'codex(gpt-5.6-sol)'   # a named model; same as codex:gpt-5.6-sol
bash "${CLAUDE_PLUGIN_ROOT}/scripts/peer-chat-spawn.sh" --harness codex --model gpt-5.6-sol
```

The user may name the peer when invoking this skill: `/peer-chat codex(astra)` or
`/peer-chat claude(fable)`, a harness (`claude` or `codex`) with an optional model in
parentheses or after a colon (`codex:astra`). The argument names the other pane only; this session
stays as it is. A model the user wrote as shorthand is yours to map: turn it into the id that
harness's CLI accepts, from what you know of its models, say the mapping in one line
(`sol-6.1 → gpt-6.1-sol`), then pass the id. The
script passes a model verbatim and maps nothing. Quote the parenthesised form in the shell. No
argument: no model flag, and the harness's own config picks the model. `"state":"already"` does not
check the running peer's model: when the user named one, spawn again with `--restart`, which that
request authorizes only while `peer_turn` is `idle`; `working` or `unknown` asks the user first.

The script works from either pane and prints one JSON object. `"state":"already"` means the requested
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
Codex defaults to embedded mode with `--no-daemon`. Pane context reaches its shell tools through
per-thread configuration and its hooks through the process env.
Set `codex_mode` to `daemon` in `.peer-chat.json`, or `PEER_CHAT_CODEX_MODE=daemon`, to start and
connect to the shared local daemon. Explicit `"--no-daemon"` in `peer_args` keeps embedded mode.
Use embedded mode for `--profile`, `--oss`, `--strict-config` and `--dangerously-bypass-hook-trust`.
When the requested harness cannot start, the script falls back on its own to the other harness
(`claude` for a Codex request, `codex` for a Claude request, neither with a model; `--fallback
<harness[:model]>` or `--fallback '<harness>(<model>)'`, `PEER_CHAT_PEER_FALLBACK` or `peer_fallback` change it, `--no-fallback` turns it
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
argv array) in a committed `.peer-chat.json` at the repo root. One exception: a set
`PEER_CHAT_PEER_HARNESS` is the user's preset and beats the flags. The env harness and its
`PEER_CHAT_PEER_MODEL` win as a pair, and a flag model counts only when the preset names no model
for that harness. When the preset overrides your request, stderr says so: tell the user in one line
which peer they got, since the preset is theirs to change. A model never moves to another harness:
a model set for one harness is dropped when the peer starts another harness. `PEER_CHAT_CLAUDE_COMMAND` / `PEER_CHAT_CODEX_COMMAND` (or `claude_command` /
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

### A held send

An open dialog in the peer pane (Claude Code's question chooser, a Codex approval prompt) shows
no live composer, and a Return there would answer the dialog with your message. Every form
waits while the peer pane shows no live composer: before anything is prepared or typed, and
again before the submit key when a dialog opened over the paste. The wait polls every 5 s on
one budget: `--wait <dur>` (`90s`, `20m`, `1h`), then `PEER_CHAT_DELIVERY_WAIT` minutes, then
`delivery_wait_minutes` in the coordinator's `.peer-chat.json`, else 60 s. A second send to the
same pane waits up to 10 s for the first one's lock.

| Exit | stderr | Next step |
| --- | --- | --- |
| 0 | the usual JSON on stdout | sent |
| 2 | `held: the peer pane shows no live composer …` | nothing typed or recorded, one agterm notice went to the user: rerun |
| 2 | `held: an earlier send is waiting for the peer's composer …` | your earlier send holds the pane and owns the notice: rerun after it exits |
| 2 | `delivery lock path is a symlink …` | nothing typed or recorded: do not rerun; tell the user, the link is theirs to inspect |
| 1 | `pasted, not submitted: …` | the text is in the peer's composer or was lost, the ledger says `uncertain`: read the pane before any resend |

After an exit 1 the text may still wait under the dialog. Once the dialog closes, the peer submits
it with `--recover-delivery` from its own pane (§ A stalled ask) or the user presses Return; until
the pane is reconciled as § Asks says, your next send to that pane is refused.

Who reruns a held send (exit 2 with `held:`), with the identical command:

- Claude Code: add `--wait 30m --no-notify` and run it with `run_in_background`; its exit wakes
  this session. When that rerun fails too, tell the user and run
  `agtermctl notify "<what failed>" --title peer-chat`.
- Codex: the notice already went out; rerun at the start of your next turn. A held send
  restores its spool file, so the same command still works.

A send that would also be refused for a missing disposition (§ Asks) learns of the refusal only
once the dialog closes. `PEER_CHAT_COMPOSER_GATE=off` skips both waits and makes every send say
so on stderr. Only the user sets it, for a harness update that breaks composer detection; an agent
never sets it, least of all to get a held send through.

Add `--state <coordinator topic>/state.json` when sending from another repository in the same
build; the default is `tmp/peer-chat/<slug>/state.json` in this repository. Every send and freeze
of the topic must use that same file. The coordinator's `.peer-chat.json` supplies configuration.

`peer-chat-paste.py` keeps the line breaks; a tab becomes one space and CR or any other control
character is dropped, so a body quoted verbatim from a web page or a bot comment pastes as it is.
It resolves the peer pane, refuses a send that leaves
a new ask from the peer without a disposition (see Asks), puts the body in through a bracketed
paste with the clipboard saved and restored around it, confirms the message's last 48
non-whitespace characters are visible in the pane, checks twice that the composer still holds
them, and sends the submit key. A draft or a suggestion in the
composer never blocks a send and is not erased, and the script does not check that the composer
cleared. Every refusal names the step;
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
is `PEER_CHAT_NAME` (the spawn sets it for the peer it launches: `codex`, or `codex gpt-5.6-sol` when a model was named) or
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
asker's pane, `❓ #left-004 …`, and reserves it atomically in `tmp/peer-chat/<slug>/state.json`, the script's own
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

The asker can abandon its own question with `#left-004 withdrawn(<why>)`. Only its asker can
withdraw it. Withdrawal closes the ask and clears its timer; report the reason at close, since
withdrawal does not prove an acceptance requirement or grant permission to skip it.
For a stopped peer, withdraw locally with `peer-chat-state.py --slug <slug> [--state <path>]
withdraw --ask-id <id> --actor-id <own bound identity> --reason '<why>' --evidence <path>`.
This records an evidenced withdrawal without sending a message to the stopped peer; the
stopped file scope still needs its own release evidence.

The sender reserves a prepared message and claims delivery under short storage transactions,
then releases `state.lock` before pane IO. `pasted` means the composer showed the text;
`submit_sent` means the submit key was sent. Neither is peer acknowledgment. An interrupted
claim stays unresolved; `--key <stable-key>` can identify the same message but never authorizes
another paste. Preserve the outbox and inspect the pane before recovery. A separate transport
lock prevents another send from replacing that outbox during the guarded Return operation.

Save the actual received peer text as evidence inside the coordinator repository. Use
`peer-chat-state.py --slug <slug> [--state <path>] observe --message-id <id>
--event acknowledged|answered --actor-id <own bound identity> --evidence <path>` to record it.
The identity is the observed `window/session/pane` composite shown by `status`; a sender cannot
acknowledge its own message. Evidence paths resolve against the coordinator repository.
For an ambiguous send keep `uncertain`. Only actual proof of non-delivery permits a sender's
`observe --event failed`; a cancelled unsent draft uses `cancelled`, both with the sender's
actor ID and nonempty evidence. A timeout alone proves neither failure nor cancellation.
To reconcile an uncertain send, inspect the peer pane without typing. A capture showing the
complete stamped message in the peer's transcript, beyond its composer, permits the sender's
`observe --event submit_sent --actor-id <own identity> --evidence <capture>`; it records the
observation without another paste or Return. The timer starts at that later observation if
no submission was recorded before. A composer-only capture permits no such classification;
use guarded recipient recovery, proven `failed`, or keep the claim unresolved and report it.

An existing TSV ledger imports once with provenance. Legacy freeze rows retain unknown repo
identity and do not become a baseline for a guessed repo. Finish active conversations using
their old plugin version, or start a fresh topic after upgrading; never mix old TSV writers
with schema-2 writers on a live topic. A transport change also needs a fresh topic.

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

An answer to your own `AskUserQuestion` that starts with `Chat from ` is a peer message that
landed in the dialog, not the user's choice. Handle it as a received peer message and ask the
user the question again.

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
back. The one timed wake is a blocking ask's timer, § A stalled ask.

A held send's background rerun (§ A held send) is not a reply wait: it watches the peer's screen,
which a person moves by closing the dialog, never the peer's answer, so it cannot deadlock.

A reply is also not promised. A model can decline to answer a message that arrived perfectly well,
and nothing reports that on either side. Never describe a sent message as though an answer were
owed, and never say the peer is "thinking about it" when all you know is that the line was typed.

## Build checks and finalization

For `/peer-chat:build`, the integrator declares every worktree and required check in an ignored
JSON spec, for example `{"repos":[{"repo":"/absolute/worktree","checks":["suite","security"]}]}`.
Include the coordinator repository. `peer-chat-state.py --slug <slug> [--state <path>]
target --spec <file>` captures the actual visible files, kinds and permissions across that set;
its `id` also covers the required check names. Each repository needs at least one required check.

Use `... check --repo <worktree> --name <check> --state passed|failed|incomplete
--target-set <id> --evidence <receipt>` after each actual check. Paths for specs and evidence
resolve inside the coordinator; receipts belong in its ignored topic directory. A target edit,
new visible file or changed required-check set needs a fresh target and checks.
Recapturing a changed set clears both confirmations. No check is green from a keystroke receipt.
Committing exactly the checked file set preserves the id, including checked deletions; an
edit made by a commit hook still invalidates it. HEAD itself is not part of this content identity.

Exchange the closing messages before confirming. Each recipient records its actual received peer
text using `observe` with its own bound actor identity and evidence. Both peers then call
`... confirm --target-set <id> --actor-id <own identity> --evidence <proof>` on the same set;
the integrator calls `... finalize --target-set <id> --actor-id <own identity>`. The gate checks
all worktrees and evidence again, requires both current confirmations, every declared check
passed on that set, a genuine two-way exchange, zero open asks and unresolved messages, and no
unresolved timer intent or unreleased stopped scope. Only `phase: finalized` completes the build.

## A stalled ask

A deliberately non-blocking ask arms nothing. If the next step needs the answer, send with
`--blocking` and a resolved deadline, grace and wake budget. Ownership handovers and held
experiments never get timers. One message has one budget tuple for all its new asks; split
messages to use different clocks or mix blocking and non-blocking questions.

Each value resolves independently: `--deadline/--grace/--wake`, then
`PEER_CHAT_STALL_MINUTES` / `PEER_CHAT_GRACE_MINUTES` / `PEER_CHAT_WAKE_MINUTES`, then
`stall_minutes` / `grace_minutes` / `wake_minutes` in the coordinator's `.peer-chat.json`, then
the agent's `--est-deadline/--est-grace/--est-wake`. Flags take positive durations such as `90s`,
`20m` or `1h`; env/profile values are positive minutes. There are no built-in time defaults,
ratios or clamps. Estimate missing values for this ask before sending; a missing budget
refuses instead of silently making the ask non-blocking.

The sent text shows each resolved duration and its source. The first `submit_sent` arms the
answer deadline; status shows its full UTC expiry. A successful nudge submission starts grace.
Preparation, retries, acknowledgments of the nudge and generic completion notifications do
not restart either clock. A working marker is not an answer and gives no automatic extension.

Run `peer-chat-state.py --slug <slug> [--state <path>] status` to inspect timers and unresolved
claims. On a wake, `... wake` returns due actions with their generation token and performs no
pane action. Its JSON holds `due`, `next_wake_at` and `wake_in_seconds`; the latter two are
null when no timer can wake. Use the tool's next wake, which is bounded by the earliest expiry.
Use a due action's exact token with `... begin --token '<JSON>' --action nudge|stop` before
any action; `null` means stale or already handled, so do nothing. Do not hold `state.lock`
while reading or writing a pane.

For a nudge, ask the peer for its current partial result and active job/resource handles,
using the checked `peer-chat-paste.py` transport, without another question glyph. Record the
observed outcome with `... finish --token '<JSON>' --action nudge --outcome ok|failed --detail
'<receipt path or error>'`. Successful completion starts grace; `... nudged --token '<JSON>'`
is shorthand for that successful finish, not a second step after it.
Never repeat an intent whose outcome is missing: inspect its actual delivery evidence first.

On grace expiry, begin the stop action and stop waiting, record its outcome with `finish`,
and report the unanswered ask. Agterm has no checked peer interrupt; type no Ctrl-C and start
no replacement peer. The peer's file scope stays reserved. The parent must reconcile every
recorded job/resource handle, save settled-job evidence and a current idle capture, then
run `... release --ask-id <id> --evidence <path>`. An idle pane alone proves no external job
finished. Timeout is not an answered/declined disposition; use the local `withdraw` operation
to abandon that question after stopping. A late reply after a stop is history, with a new ask
only when it reveals a defect.

Claude Code can schedule one background Bash sleep until the next selected wake; its completion
re-invokes the session. Use the configured wake interval, bounded by the remaining answer or
grace time, and recheck the token after waking. A stale token is a no-op. Codex has no self-wake:
use bounded native waits only inside an active parent turn, or check due actions on the next
turn. Never claim a background process will resume an ended Codex turn.

At an agterm wake, consume a received reply first. An own composer containing the recorded
message can use `peer-chat-paste.py --to peer --recover-delivery --slug <slug>` with the same
`--state` when needed. Its two exact-text reads guard the Return; unrelated or collapsed text
stays untouched. Before expiry an idle peer may receive one reminder through the checked
transport; a working or unknown pane receives none. Reminders never extend the answer budget.

## What you may not do

Use the checked transport for pane input. The paste wrapper deliberately ignores drafts,
suggestions and cursor position for both harnesses; its target, dialog and paste-confirmation
checks still apply. The one exception is the launch line `peer-chat-spawn.sh` types into a fresh shell prompt,
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
