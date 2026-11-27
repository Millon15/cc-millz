# 🗣️ peer-chat

    /plugin install peer-chat@cc-millz          # Claude Code
    codex plugin add peer-chat@cc-millz         # Codex
    bash ~/.claude/plugins/cache/cc-millz/peer-chat/*/scripts/peer-chat-install.sh

Two coding agents hold a conversation in one agterm split, each typing into the other's composer: Claude Code and Codex, two Claudes, or two Codexes, any model on either side. You read both halves without relaying anything by hand. The value is disagreement: a second agent with its own context attacks the first one's reasoning, and what comes back is a located disagreement or a checked fact.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal 0.44.1+ (macOS), `python3` 3.10+, `jq`, and the `claude` or `codex` CLI for each side. Outside agterm nothing is typed: sends and the spawn refuse, while `peer-chat-spawn.sh --explain` and the installer still work.

## Core ideas

- **Equal peers, one skill.** Both panes load the same `skills/peer-chat/SKILL.md`; neither side is special, and the pair can be `claude:opus` + `claude:fable`, `codex:gpt-5.6-sol` + `codex:gpt-6-astra`, or any mix. A participant is a pane slot (`left` / `right`); the peer is the other slot.
- **Vendored engine, local adapter.** `scripts/vendor/peer-chat.py` and its 135 tests are umputun's [two-agent-chat](https://github.com/umputun/agterm/tree/master/cookbook/two-agent-chat) recipe, byte for byte, pinned by sha256 in `UPSTREAM.md`. Upstream pairs Claude with the left pane and Codex with the right; `scripts/peer-chat.py` drops that pairing by building the engine's profile from the pane slots and from the harness it finds running in the target pane.
- **Either agent brings the peer in.** `peer-chat-spawn.sh` works from either pane: it opens the other pane, types exactly one short launch line, `/bin/sh <private launcher>`, whose script holds the full command with the pane's session context (macOS drops a line typed past 1024 bytes before the shell is ready), and waits until agterm reports the requested harness. The default peer is `codex` with the model its own config sets; `claude`, `'codex(gpt-5.6-sol)'`, `claude:fable` or `--harness codex --model gpt-5.6-sol` pick another. `/peer-chat codex(sol-6.1)` names the peer when invoking the skill; the calling agent maps a shorthand model to a real id, and the script passes it verbatim. A peer that cannot start (executable missing, never appears, or the other harness already sits in the pane) falls back to the other harness, with no model, and the result says `fallback_from`. Every later keystroke goes through `peer-chat.py`'s checks.
- **The peers organize the work.** There is no fixed writer, reviewer or lead. Before editing, the peers agree who owns which files or which worktree; disjoint owners are fine, overlapping writes need an explicit release and acceptance, and no peer agreement widens what the user authorized.
- **A ledger the user can follow in a thin pane, at any length.** Every message is an emoji ledger, one segment per line: `🎯` claim, `🔎` evidence as `path:line` or a proof path, `📎` an artifact with how to run it and what it showed, `❓` a question. There is no line or character cap: `peer-chat-paste.py` carries the line breaks (one bracketed paste typed through `agtermctl session type`, never the clipboard, so a sandboxed Codex sends too; a draft or suggestion in the composer never blocks it, and an open dialog in the peer pane holds the send until it closes) and wraps prose at 50 columns on a word boundary.
- **Every thought in the chat, only artifacts in files.** Scripts, outputs, queries, HTML and fixtures go to `tmp/peer-chat/<slug>/` under the repo root as `NN-<pane>-<what>.<ext>`; both agents write there and the record outlives the session. Reasoning never goes to a `.md` or `.txt`.
- **An ask ledger the script enforces.** `peer-chat-paste.py --slug <topic>` stamps every `❓` with an id named after the asker's pane (`#left-004`) and records it in `tmp/peer-chat/<topic>/asks.tsv`. The peer's next send must carry `answered`, `deferred(<when>)` or `declined(<why>)` for each new ask, or it is refused; a deferral older than 20 minutes comes back as `overdue:`. Ledgers from before pane ids keep their `#claude-NNN` / `#codex-NNN` ids, read as left / right.
- **Positions are checked, and reversals are named.** A peer's claim is accepted only as `accepted: "<their words>"; checked <path:line>`; a dropped position is announced as `🎯 I said X; Y is right because Z`; "fixed" is claimed only by quoting the re-run of the peer's own proof.
- **Proofs beat agreed readings.** A disputed claim about runtime behaviour gets a proof before the next send: `/plan:research` (plugin `plan@cc-millz`) or `plan-research.sh`; `plan-research.sh --slug <s> --verify <n>` re-runs a proof against its `proof.json` contract.
- **No prompt is ever answered for you.** Trust dialogs, login, permission requests and choosers are the user's; the skill stops and reports.
- **A stale address is recovered, never guessed.** A resumed session can inherit the session and window ids of a split that no longer exists. The skill then inspects the live split read-only and retries with explicit `--session` / `--window` selectors only when exactly one pair of panes shows this conversation; anything less goes to the user. A failed multi-line send keeps its spool body, so the retry starts from the same text after a look at the peer's screen.

## Components

Model shorthand works in both `/peer-chat codex(astra)` and `/peer-chat claude(fable)`.
`/peer-chat:build path/to/design.md codex(astra)` takes the same peer argument, including
the `codex:astra` form or `--peer=codex:astra`. The calling agent states the mapping to an
accepted model id before spawning. With no model override, the peer starts on its harness's
own configuration.

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `peer-chat` | 🗣️ one body for every harness: preflight, spawn, send, receive, organizing the work, manners |
| skill | `/peer-chat:build` | 🏗️ implement a proposed design with the peer: pin it to a file, two lanes with disjoint files and written contracts, explicit acceptance before edits, frozen review targets, every acceptance check recorded, commits under the project's policy |
| script | `scripts/peer-chat.py` | 📨 the adapter: resolves the peer pane and its harness, labels the sender, hands delivery to the engine; one line; a send with `--slug` or `--queue` goes to the paste sender instead |
| script | `scripts/vendor/peer-chat.py` | 🧱 the vendored engine: composer and caret checks, 197-byte marked events, submit confirmation |
| script | `scripts/peer-chat-paste.py` | 📄 the multi-line send: resolves the peer, enforces the ask ledger (`--slug`), waits out a dialog in the peer pane (`--wait`, exit 2 and one notice when it outlasts the budget), wraps prose, bracketed paste, confirms the tail in the composer, submits |
| script | `scripts/peer-chat-review-page.py` | 💬 render a `proposal-vN.md` as a commentable agterm page (`peer-chat-review-page.html`), wait until the user sends, save `NN-user-comments-vN.json` in the topic dir; exit 3 when the page closes unsent |
| script | `scripts/peer-chat-spawn.sh` | 🪟 open the other pane and start any harness + model; falls back to the other harness when the requested one cannot start (`--fallback`, `--no-fallback`); `--restart` relaunches the peer after an update; `--explain` prints the resolved config |
| script | `scripts/peer-chat-install.sh` | 🔧 copy the adapter, engine and paste sender onto PATH and write the three Codex approval rules; `--check` reports |
| script | `scripts/sync-upstream.sh` | 🔄 re-vendor from umputun/agterm, re-pin the sha256 and stage upstream's skill files for a hand merge |
| hook | `SessionStart` | 🔔 `scripts/session-start-peer.sh agterm` injects the peer-mode directive on startup, resume, clear and compact. Opt-in through `~/.claude/peer-chat.mode`; text only, it never opens a pane |

## Peer mode on every session

Installing the plugin changes no session. To start every interactive `claude` or `codex` inside agterm in peer mode, without typing `/peer-chat`, write the marker file:

    echo agterm > ~/.claude/peer-chat.mode

The SessionStart hook then adds one directive to the session's context, in three tiers:

| The task | What the agent does |
|----------|---------------------|
| a lookup, a typo, a one-line fix | works alone |
| a decision with two defensible options, a root cause, a diff about to ship | loads `peer-chat:peer-chat` and brings the peer in |
| an agreed multi-file design | runs `peer-chat:build` |

- **Text only.** The hook opens no pane. The other pane opens when the skill sends its first message, so a session that never reaches the second tier never gets a peer.
- **Every SessionStart source.** The directive comes back after resume, clear and compact, because compaction drops it with the loaded skills.
- **One marker for both plugins.** Its first line is `agterm` (this plugin), `bg` ([peer-chat-bg](../peer-chat-bg/README.md), no agterm needed) or `0`. A missing file, `0` or any other value keeps both hooks silent.
- **Where the marker lives.** `CLAUDE_CONFIG_DIR` moves it with the rest of `~/.claude`, and a `PEER_CHAT_MODE` shell export overrides it for one run. Do NOT put `PEER_CHAT_MODE` in a settings.json `env` block: that block never reaches hook processes.
- **Codex approval.** Codex runs a plugin hook only after you approve it, once per machine. Approve the new SessionStart hook when Codex shows it; the approval is stored under `[hooks.state]` in `~/.codex/config.toml`. Until then Codex sessions start without the directive, and Claude Code sessions are not affected.

With the marker on `agterm`, the hook still stays silent in four cases:

| Case | How the hook sees it |
|------|----------------------|
| outside agterm | `AGTERM_ENABLED` is not `1` |
| the peer the spawn started | `PEER_CHAT_NAME` is set, so a peer never asks for a peer of its own |
| an SDK run such as `claude -p` | `CLAUDE_CODE_ENTRYPOINT` starts with `sdk` |
| an agent started by another agent | two or more parent processes are named `claude` or `codex` |

- **Why the last case reads processes.** Env cannot show it: a `codex exec` started from a Claude session inherits `CLAUDE_CODE_ENTRYPOINT=cli` and `AGTERM_ENABLED=1`, and Codex's SessionStart payload has no field for a headless run.
- **How it counts.** The hook walks its parent processes up to pid 1 and counts the ones whose `ps -o comm=` basename is `claude` or `codex`; a wrapper named in `PEER_CHAT_CLAUDE_COMMAND` or `PEER_CHAT_CODEX_COMMAND` counts too.

## Config

Flags win, then env, then a committed `.peer-chat.json` at the repo root, then the default. `peer-chat-spawn.sh --explain` prints every value with its source.

The harness and the model resolve as one pair:

- **An env preset beats the flags.** With `PEER_CHAT_PEER_HARNESS` set, the env harness and `PEER_CHAT_PEER_MODEL` win over `--harness`, `--model` and a positional peer, and stderr names the override. A flag model fills in only when the preset has no model and asks for the same harness.
- **A model never moves to another harness.** A `peer_model` from `.peer-chat.json` applies only to that file's `peer_harness` (default `codex`). Asking for another harness drops it, so the new harness uses its own model config, and `--explain` shows `null` from `default`.

| key | env | default | what |
|-----|-----|---------|------|
| `peer_harness` | `PEER_CHAT_PEER_HARNESS` | `codex` | the harness the spawn starts: `claude` or `codex` (`--harness`) |
| `peer_model` | `PEER_CHAT_PEER_MODEL` | none | passed verbatim as `--model` (`--model`); with none, `--explain` shows `null` and the harness keeps the model its own config sets |
| `peer_fallback` | `PEER_CHAT_PEER_FALLBACK` | `claude` for codex, `codex` for claude | `harness[:model]` or `harness(model)` started when the peer cannot: executable missing, no appearance within `start_timeout`, or that harness already in the pane (`--fallback`, `--no-fallback`); `none` disables; the result carries `fallback_from` |
| `peer_args` | `PEER_CHAT_PEER_ARGS` | `[]` | extra launch arguments as a JSON string array; a model flag here is refused, use `peer_model` |
| `codex_mode` | `PEER_CHAT_CODEX_MODE` | `embedded` | `embedded` launches with `--no-daemon`; `daemon` connects to the shared local daemon |
| `codex_command` | `PEER_CHAT_CODEX_COMMAND` | `codex` | the name agterm reports for a wrapped Codex |
| `claude_command` | `PEER_CHAT_CLAUDE_COMMAND` | `claude` | the name agterm reports for a wrapped Claude |
| `start_timeout` | `PEER_CHAT_START_TIMEOUT` | `30` | seconds to wait for the peer to appear, and for the old one to exit on `--restart` |

`peer-chat.py` reads `AGTERM_PANE`, `AGTERM_SESSION_ID`, `AGTERM_WINDOW_ID`, `PEER_CHAT_NAME` (the sender name in the `Chat from <name>:` label; the spawn sets it for the peer) and the two `PEER_CHAT_*_COMMAND` variables. `--to peer` is the default target; `--to left|right` names a slot, and the legacy `--to claude|codex` resolves to the one pane running that harness.

`peer-chat-paste.py` adds `--slug` (or `PEER_CHAT_SLUG`) for the ask ledger, `--queue` (a Codex peer only: Tab when its screen still reads `working` after the paste, Return when idle or unreadable), `PEER_CHAT_WRAP` (default `50`, `0` disables the wrap) and `PEER_CHAT_DEFER_MINUTES` (default `20`, when a deferred ask turns overdue).

## Limits

- Codex peers default to embedded mode with `--no-daemon`, including when `peer_args` contains other options. Pane variables are passed twice: as an `env K=V` prefix on the launch command, which Codex hooks read, and as per-thread `-c` overrides, which its shell tools read.
- Set `codex_mode` to `daemon` in `.peer-chat.json`, or set `PEER_CHAT_CODEX_MODE=daemon`, to use the shared local daemon. The launcher starts it, connects through its Unix socket, and passes the caller's working directory. Explicit `--no-daemon` in `peer_args` overrides daemon mode.
- `--profile`, `--oss`, `--strict-config`, and `--dangerously-bypass-hook-trust` require embedded mode. Peer-chat selects the runtime, so `--remote` in `peer_args` is rejected. A daemon-mode Codex wrapper must accept `app-server daemon start`; a failed or timed-out start follows the configured harness fallback.
- Each send resolves a stable agterm pane token and uses it through submission. Promotion keeps the same recipient. A pane replacement during the send makes the old token fail. When supplied, `AGTERM_SOCKET` selects the app for every call.
- A model name reaches the harness verbatim; an unknown one fails inside the harness, not before the launch.
- `peer_turn` and the mid-turn warning come from screen text, matched against the markers Claude Code and Codex draw today (a spinner line with a timer, `Working (… esc to interrupt)`); a harness that redraws them reads as `unknown`, which never warns and never blocks.
- The peer-mode hook's parent-process check can miss a nested agent and never invents one. A harness whose process shows under another name (`node` for an npm-installed CLI, a wrapper not named in `PEER_CHAT_*_COMMAND`) is not counted, and a headless run started from it gets the directive. The cost is one paragraph of context: the hook opens no pane.
- The hook picks no peer. `peer_harness` and `peer_model` resolve at spawn time exactly as the Config table says.

## Updating

Schema 2 stores asks, delivery observations, per-repository freezes and timers in one
`tmp/peer-chat/<slug>/state.json`. Pass `--state <path>` to sends, freezes and
`peer-chat-state.py` when a lane works in another repository. Legacy TSV files import with
provenance; unknown-repository freeze rows remain historical. Finish live topics on their
old version or start a fresh topic after upgrading.

For a question the next step needs, send `--blocking` with `--deadline`, `--grace` and `--wake`
durations such as `20m`, or their `--est-` forms for agent estimates. Environment and project
configuration can supply values too; each value's source appears in the message. No fixed
clock or automatic progress extension applies. `peer-chat-state.py --slug <slug> status|wake`
reports timers without driving the pane; the skill gives the intent/action/receipt procedure.

Builds declare repositories and required checks with `peer-chat-state.py --slug <slug>
target --spec <file>`. Include the coordinator in the spec:

```json
{"repos":[{"repo":"/absolute/worktree","checks":["suite","security"],"paths":["src","tests"]}]}
```

- **Scope.** Omit `paths` to cover the whole worktree. To narrow it, name a nonempty list of unique, literal
  repo-relative files or directories without `..` segments. Include the build files and inputs the checks use.
- **Identity.** The target id binds the path selection, in-scope tracked and unignored untracked file bytes, kinds,
  modes and required checks. An edit inside scope invalidates the target. Committing the checked bytes preserves it.
- **Confirmation.** Record checks, exchange recipient acknowledgments, and have both peers `confirm` the same id.
  Name the verified scope in each confirmation receipt. The integrator calls `finalize` after both confirmations.

Re-run `peer-chat-install.sh` after a plugin version bump: the files on PATH are copies, not symlinks, because a symlink into the plugin cache breaks the moment the cache dir changes. Then `peer-chat-spawn.sh --restart`, since a running agent never reloads its skills.

---

Part of [cc-millz](../../README.md).
