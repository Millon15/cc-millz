# 🗣️ peer-chat

    /plugin install peer-chat@cc-millz
    bash ~/.claude/plugins/cache/cc-millz/peer-chat/*/scripts/peer-chat-install.sh

Claude Code and Codex hold a conversation in one agterm split, each typing a line into the other's composer. You read both halves without relaying anything by hand. The value is disagreement: a second agent with its own context attacks the first one's reasoning, and what comes back is a located disagreement or a checked fact.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal 0.24.0+ (macOS), `python3` 3.10+, `jq`, and the `codex` CLI. Outside agterm every script exits 4 and nothing is typed.

## Core ideas

- **Vendored recipe, one departure.** `peer-chat.py` and its 135 tests are umputun's [two-agent-chat](https://github.com/umputun/agterm/tree/master/cookbook/two-agent-chat) recipe, byte for byte (see `UPSTREAM.md`). Upstream leaves starting Codex to the human; this plugin lets Claude open the pane itself.
- **Claude decides when a colleague is worth it.** The skill fires on "work with codex" and friends, on an incoming `Chat from Codex:`, and on its own when a decision would be better for an adversary: a design with two defensible options, a root cause nobody has tried to disprove, a diff about to ship unreviewed. It says so in one line first; closing the pane ends the exchange.
- **The spawn types exactly one line.** `peer-chat-spawn.sh` opens the split, watches a shell prompt draw, types the codex launch line with this pane's session id injected (`shell_environment_policy.set.AGTERM_SESSION_ID`, since Codex strips it from tool subprocesses), and waits until agterm reports codex as the pane's foreground. Every later keystroke goes through `peer-chat.py`'s checks.
- **Sole-writer rule survives.** The agent that received the user's request writes; the one brought in by a `Chat from` message or by the spawn stays read-only and hands patches over as mode-0600 temp files with a SHA-256.
- **No prompt is ever answered for you.** Trust dialogs, login, permission requests and choosers are the user's; both skills stop and report.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `peer-chat` | 🗣️ Claude side: preflight, spawn, send, receive, shared-work rules, manners |
| file | `codex/SKILL.md` | 🤖 Codex side, installed to `~/.codex/skills/peer-chat/SKILL.md` by the installer |
| script | `scripts/peer-chat.py` | 📨 the vendored transport: composer and caret checks, 197-byte marked events, submit confirmation |
| script | `scripts/peer-chat-spawn.sh` | 🪟 open the split and start Codex; `--explain` prints the resolved config |
| script | `scripts/peer-chat-install.sh` | 🔧 copy `peer-chat.py` onto PATH, install the Codex skill and its two approval rules; `--check` reports |
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

## Layout

Claude Code in the main (left) pane, Codex in the split (right) pane, one session. `peer-chat.py` hard-codes that, so a Claude running in a right pane gets exit 4 from the spawn and a plain refusal from a send.

## Updating

Re-run `peer-chat-install.sh` after a plugin version bump: the copy of `peer-chat.py` on PATH is a copy, not a symlink, because a symlink into the plugin cache breaks the moment the cache dir changes.

---

Part of [cc-millz](../../README.md).
