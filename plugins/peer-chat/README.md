# 🗣️ peer-chat

    /plugin install peer-chat@cc-millz
    bash ~/.claude/plugins/cache/cc-millz/peer-chat/*/scripts/peer-chat-install.sh

Claude Code and Codex hold a conversation in one agterm split, each typing a line into the other's composer. You read both halves without relaying anything by hand. The value is disagreement: a second agent with its own context attacks the first one's reasoning, and what comes back is a located disagreement or a checked fact.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal 0.24.0+ (macOS), `python3` 3.10+, `jq`, and the `codex` CLI. Outside agterm every script exits 4 and nothing is typed.

## Core ideas

- **Vendored recipe, one departure.** `peer-chat.py` and its 135 tests are umputun's [two-agent-chat](https://github.com/umputun/agterm/tree/master/cookbook/two-agent-chat) recipe, byte for byte (see `UPSTREAM.md`). Upstream leaves starting Codex to the human; this plugin lets Claude open the pane itself.
- **Claude decides when a colleague is worth it.** The skill fires on "work with codex" and friends, on an incoming `Chat from Codex:`, and on its own when a decision would be better for an adversary: a design with two defensible options, a root cause nobody has tried to disprove, a diff about to ship unreviewed. It says so in one line first; closing the pane ends the exchange.
- **The spawn types exactly one line.** `peer-chat-spawn.sh` opens the split, watches a shell prompt draw, types the codex launch line with this pane's session id injected (`shell_environment_policy.set.AGTERM_SESSION_ID`, since Codex strips it from tool subprocesses), and waits until agterm reports codex as the pane's foreground. Every later keystroke goes through `peer-chat.py`'s checks.
- **A ledger the user can follow in a thin pane, at any length.** Every message is an emoji ledger, one segment per line: `🎯` claim, `🔎` evidence as `path:line` or a proof path, `📎` an artifact with how to run it and what it showed, `❓` a question. There is no line or character cap: a thought takes the lines it needs, and `peer-chat-paste.py` carries the line breaks (a bracketed paste through the clipboard, saved and restored, with composer occupancy ignored for both agents) and wraps prose at 50 columns on a word boundary. The point is that the human reading both panes can follow the argument, catch a domain mistake and interrupt either side.
- **Every thought in the chat, only artifacts in files.** Scripts, outputs, queries, HTML and fixtures go to `tmp/peer-chat/<slug>/` under the repo root as `NN-<agent>-<what>.<ext>`; both agents write there and the record outlives the session. Reasoning, agreed lists and retros never go to a `.md` or `.txt`; a peer that finds one names it, and the author sends the content as chat.
- **An ask ledger the script enforces.** `peer-chat-paste.py --slug <topic>` stamps every `❓` with a topic-scoped id (`#claude-004`) and records it in `tmp/peer-chat/<topic>/asks.tsv`. The peer's next send must carry `#claude-004 answered`, `deferred(<when>)` or `declined(<why>)` for each new ask, or it is refused with the questions listed; a deferral older than 20 minutes is prepended to the deferrer's next send as `overdue:`. A `❓` with no `🔎` in the message draws a warning: one check of your own before asking.
- **Positions are checked, and reversals are named.** A peer's claim is accepted only as `accepted: "<their words>"; checked <path:line>`; a dropped position is announced as `🎯 I said X; Y is right because Z` before the new claim; "fixed" is claimed only by quoting the re-run of the peer's own proof, otherwise it is `🎯 unproven:`.
- **Proofs beat agreed readings.** A disputed claim about runtime behaviour gets a proof before the next send: Claude runs `/plan:research` (plugin `plan@cc-millz`), Codex runs `plan-research.sh` or a script of its own; an undisputed measurement stays a hand script under `tmp/peer-chat/<slug>/`. `plan-research.sh --slug <s> --verify <n>` re-runs a proof against its `proof.json` contract and exits 0 only when every case still matches, which is the line a "fixed" claim quotes.
- **Peers exchange roles autonomously.** Either agent can request a swap: the current writer stops edits and releases the role, then the peer explicitly accepts it. No user reassignment is needed. One writer per worktree remains; the other reviews, and the latest handoff survives interruptions. Task scope and user approval boundaries stay unchanged.
- **No prompt is ever answered for you.** Trust dialogs, login, permission requests and choosers are the user's; both skills stop and report.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `peer-chat` | 🗣️ Claude side: preflight, spawn, send, receive, shared-work rules, manners |
| file | `codex/SKILL.md` | 🤖 Codex side, installed to `~/.codex/skills/peer-chat/SKILL.md` by the installer |
| script | `scripts/peer-chat.py` | 📨 the vendored transport: composer and caret checks, 197-byte marked events, submit confirmation; one line |
| script | `scripts/peer-chat-paste.py` | 📄 the multi-line send: checks the target, ignores composer occupancy before/after sending, enforces the ask ledger (`--slug`), wraps prose, bracketed paste, confirms the tail, submits |
| script | `scripts/peer-chat-spawn.sh` | 🪟 open the split and start Codex; `--restart` quits and relaunches it after a skill update; `--explain` prints the resolved config |
| script | `scripts/peer-chat-install.sh` | 🔧 copy both senders onto PATH, install the Codex skill and its three approval rules; `--check` reports |
| script | `scripts/sync-upstream.sh` | 🔄 re-vendor from umputun/agterm and stage the two skill files for a hand merge |

## Config

Env wins, then a committed `.peer-chat.json` at the repo root, then the default. `peer-chat-spawn.sh --explain` prints every value with its source.

| key | env | default | what |
|-----|-----|---------|------|
| `codex_args` | `PEER_CHAT_CODEX_ARGS` | *(empty)* | extra flags on the launch line, e.g. `--profile review` |
| `codex_command` | `PEER_CHAT_CODEX_COMMAND` | `codex` | the name agterm reports for a wrapped Codex |
| `claude_command` | `PEER_CHAT_CLAUDE_COMMAND` | `claude` | the name agterm reports for a wrapped Claude |
| `start_timeout` | `PEER_CHAT_START_TIMEOUT` | `30` | seconds to wait for codex to appear in the right pane |

`peer-chat.py` itself reads `AGTERMCTL` and the two `PEER_CHAT_*_COMMAND` variables; see upstream's README for `--session`, `--window`, `--queue` and `--target-command`.

`peer-chat-paste.py` adds `--slug` (or `PEER_CHAT_SLUG`) for the ask ledger, `PEER_CHAT_WRAP` (default `50`, `0` disables the wrap) and `PEER_CHAT_DEFER_MINUTES` (default `20`, when a deferred ask turns overdue).

## Layout

Claude Code in the main (left) pane, Codex in the split (right) pane, one session. `peer-chat.py` hard-codes that, so a Claude running in a right pane gets exit 4 from the spawn and a plain refusal from a send.

## Updating

Re-run `peer-chat-install.sh` after a plugin version bump: the copy of `peer-chat.py` on PATH is a copy, not a symlink, because a symlink into the plugin cache breaks the moment the cache dir changes.

---

Part of [cc-millz](../../README.md).
