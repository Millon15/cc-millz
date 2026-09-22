# 🗣️ peer-chat

    /plugin install peer-chat@cc-millz          # Claude Code
    codex plugin add peer-chat@cc-millz         # Codex
    bash ~/.claude/plugins/cache/cc-millz/peer-chat/*/scripts/peer-chat-install.sh

Two coding agents hold a conversation in one agterm split, each typing into the other's composer: Claude Code and Codex, two Claudes, or two Codexes, any model on either side. You read both halves without relaying anything by hand. The value is disagreement: a second agent with its own context attacks the first one's reasoning, and what comes back is a located disagreement or a checked fact.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal 0.24.0+ (macOS), `python3` 3.10+, `jq`, and the `claude` or `codex` CLI for each side. Outside agterm nothing is typed: sends and the spawn refuse, while `peer-chat-spawn.sh --explain` and the installer still work.

## Core ideas

- **Equal peers, one skill.** Both panes load the same `skills/peer-chat/SKILL.md`; neither side is special, and the pair can be `claude:opus` + `claude:fable`, `codex:gpt-5.6-sol` + `codex:gpt-6-astra`, or any mix. A participant is a pane slot (`left` / `right`); the peer is the other slot.
- **Vendored engine, local adapter.** `scripts/vendor/peer-chat.py` and its 135 tests are umputun's [two-agent-chat](https://github.com/umputun/agterm/tree/master/cookbook/two-agent-chat) recipe, byte for byte, pinned by sha256 in `UPSTREAM.md`. Upstream pairs Claude with the left pane and Codex with the right; `scripts/peer-chat.py` drops that pairing by building the engine's profile from the pane slots and from the harness it finds running in the target pane.
- **Either agent brings the peer in.** `peer-chat-spawn.sh` works from either pane: it opens the other pane, types exactly one launch line with the pane's session context injected, and waits until agterm reports the requested harness. The default peer is `codex` on `gpt-6-astra`; `claude:fable`, `--harness codex --model gpt-5.6-sol` and friends pick another. Every later keystroke goes through `peer-chat.py`'s checks.
- **The peers organize the work.** There is no fixed writer, reviewer or lead. Before editing, the peers agree who owns which files or which worktree; disjoint owners are fine, overlapping writes need an explicit release and acceptance, and no peer agreement widens what the user authorized.
- **A ledger the user can follow in a thin pane, at any length.** Every message is an emoji ledger, one segment per line: `🎯` claim, `🔎` evidence as `path:line` or a proof path, `📎` an artifact with how to run it and what it showed, `❓` a question. There is no line or character cap: `peer-chat-paste.py` carries the line breaks (a bracketed paste through the clipboard, saved and restored, with composer occupancy ignored for both harnesses) and wraps prose at 50 columns on a word boundary.
- **Every thought in the chat, only artifacts in files.** Scripts, outputs, queries, HTML and fixtures go to `tmp/peer-chat/<slug>/` under the repo root as `NN-<pane>-<what>.<ext>`; both agents write there and the record outlives the session. Reasoning never goes to a `.md` or `.txt`.
- **An ask ledger the script enforces.** `peer-chat-paste.py --slug <topic>` stamps every `❓` with an id named after the asker's pane (`#left-004`) and records it in `tmp/peer-chat/<topic>/asks.tsv`. The peer's next send must carry `answered`, `deferred(<when>)` or `declined(<why>)` for each new ask, or it is refused; a deferral older than 20 minutes comes back as `overdue:`. Ledgers from before pane ids keep their `#claude-NNN` / `#codex-NNN` ids, read as left / right.
- **Positions are checked, and reversals are named.** A peer's claim is accepted only as `accepted: "<their words>"; checked <path:line>`; a dropped position is announced as `🎯 I said X; Y is right because Z`; "fixed" is claimed only by quoting the re-run of the peer's own proof.
- **Proofs beat agreed readings.** A disputed claim about runtime behaviour gets a proof before the next send: `/plan:research` (plugin `plan@cc-millz`) or `plan-research.sh`; `plan-research.sh --slug <s> --verify <n>` re-runs a proof against its `proof.json` contract.
- **No prompt is ever answered for you.** Trust dialogs, login, permission requests and choosers are the user's; the skill stops and reports.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `peer-chat` | 🗣️ one body for every harness: preflight, spawn, send, receive, organizing the work, manners |
| script | `scripts/peer-chat.py` | 📨 the adapter: resolves the peer pane and its harness, labels the sender, hands delivery to the engine; one line |
| script | `scripts/vendor/peer-chat.py` | 🧱 the vendored engine: composer and caret checks, 197-byte marked events, submit confirmation |
| script | `scripts/peer-chat-paste.py` | 📄 the multi-line send: resolves the peer, ignores composer occupancy, enforces the ask ledger (`--slug`), wraps prose, bracketed paste, confirms the tail, submits |
| script | `scripts/peer-chat-spawn.sh` | 🪟 open the other pane and start any harness + model; `--restart` relaunches the peer after an update; `--explain` prints the resolved config |
| script | `scripts/peer-chat-install.sh` | 🔧 copy the adapter, engine and paste sender onto PATH and write the three Codex approval rules; `--check` reports |
| script | `scripts/sync-upstream.sh` | 🔄 re-vendor from umputun/agterm, re-pin the sha256 and stage upstream's skill files for a hand merge |

## Config

Flags win, then env, then a committed `.peer-chat.json` at the repo root, then the default. `peer-chat-spawn.sh --explain` prints every value with its source.

| key | env | default | what |
|-----|-----|---------|------|
| `peer_harness` | `PEER_CHAT_PEER_HARNESS` | `codex` | the harness the spawn starts: `claude` or `codex` (`--harness`) |
| `peer_model` | `PEER_CHAT_PEER_MODEL` | `gpt-6-astra` for codex, none for claude | passed verbatim as `--model` (`--model`); with none, `--explain` shows `null` and Claude keeps its own default |
| `peer_args` | `PEER_CHAT_PEER_ARGS` | `[]` | extra launch arguments as a JSON string array; a model flag here is refused, use `peer_model` |
| `codex_command` | `PEER_CHAT_CODEX_COMMAND` | `codex` | the name agterm reports for a wrapped Codex |
| `claude_command` | `PEER_CHAT_CLAUDE_COMMAND` | `claude` | the name agterm reports for a wrapped Claude |
| `start_timeout` | `PEER_CHAT_START_TIMEOUT` | `30` | seconds to wait for the peer to appear, and for the old one to exit on `--restart` |

`peer-chat.py` reads `AGTERM_PANE`, `AGTERM_SESSION_ID`, `AGTERM_WINDOW_ID`, `PEER_CHAT_NAME` (the sender name in the `Chat from <name>:` label; the spawn sets it for the peer) and the two `PEER_CHAT_*_COMMAND` variables. `--to peer` is the default target; `--to left|right` names a slot, and the legacy `--to claude|codex` resolves to the one pane running that harness.

`peer-chat-paste.py` adds `--slug` (or `PEER_CHAT_SLUG`) for the ask ledger, `PEER_CHAT_WRAP` (default `50`, `0` disables the wrap) and `PEER_CHAT_DEFER_MINUTES` (default `20`, when a deferred ask turns overdue).

## Limits

- The peer is addressed by pane slot. After a promote or re-split puts a different agent of the same harness into that slot, the foreground check cannot tell them apart.
- A model name reaches the harness verbatim; an unknown one fails inside the harness, not before the launch.

## Updating

Re-run `peer-chat-install.sh` after a plugin version bump: the files on PATH are copies, not symlinks, because a symlink into the plugin cache breaks the moment the cache dir changes. Then `peer-chat-spawn.sh --restart`, since a running agent never reloads its skills.

---

Part of [cc-millz](../../README.md).
