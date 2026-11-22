# 🗣️ Background peer chat

An equal coding peer without agterm: one plugin for Claude Code's native background agents
and Codex's native collaboration tools. `/peer-chat-bg:peer-chat` discusses or reviews;
`/peer-chat-bg:build` implements an agreed design through accepted lanes, frozen cross-review
targets and recorded acceptance checks.

- 🎯 **Scoped targets:** Use `target --output tmp/peer-chat-bg/target.json --path src --path tests`
  to cover selected repository paths in a fresh Git-ignored manifest. Each `--path` is a literal
  repository-relative file or directory. Choose the paths needed for the build and its checks,
  and name the scope in confirmation evidence. Omit `--path` to verify the whole worktree.
- 🧩 **Shared machinery:** question parsing/ledger and the build protocol have canonical sources
  under `shared/peer-chat/`. Deterministic generators package self-contained copies into both
  plugins; CI checks drift. Installed plugin caches need no sibling checkout or symlinks.
- 🧾 **Honest delivery:** prepared → dispatching → submitted → acknowledged → answered.
  Submission is not an answer; a crash after dispatch is uncertain, never an automatic resend.
- ⏱️ **Answer budgets:** a blocking ask carries its own deadline and grace (flag, env, profile,
  or the agent's estimate, each source shown in a `⏱` line). Past the deadline the parent nudges
  once, past the grace it stops the child; every wake is token-checked, so a stale one does
  nothing, and an action is recorded as an intent before the native call and an outcome after.
- 🤝 **Native scope:** Codex peers run in Codex; Claude peers run in Claude. Cross-runtime
  Claude ↔ Codex pairing still requires a bridge, such as the original agterm plugin.
- 🔐 **Authority:** no permission-rule installation, shell bypass flags, hidden CLI launches,
  credential copying or model substitution. Host sandbox/approval policy remains authoritative.
- 🧪 **Proofs:** `plan:research` is optional for empirical investigations; its proof contracts
  are rerunnable. Install `plan@cc-millz` separately when needed.

## 📦 Install

Claude Code:

```text
/plugin marketplace add Millon15/cc-millz
/plugin install peer-chat-bg@cc-millz
/reload-plugins
/peer-chat-bg:peer-chat Review this design with a background peer
/peer-chat-bg:build path/to/design.md --slug my-feature
```

Codex (from a checkout):

```bash
codex plugin marketplace add /absolute/path/to/cc-millz
codex plugin add peer-chat-bg@cc-millz
codex plugin add plan@cc-millz
codex plugin list --json
```

Start a fresh Codex thread after installation. The plugin supplies `peer-chat` and `build`
skills under the `peer-chat-bg` namespace; use the client skill picker if its UI does not
render Claude-style slash commands. The CLI cannot hot-replace an already-running thread's
tool catalog. Neither installation nor registration proves that a host supports native peers;
the skill preflights the actual tools before use.

## 🔔 Peer mode on every session

Installing the plugin changes no session. To start every interactive session in peer mode,
without typing `/peer-chat-bg:peer-chat`, write the marker file:

```bash
echo bg > ~/.claude/peer-chat.mode
```

The SessionStart hook (`scripts/session-start-peer.sh bg`) then adds one directive to the
session's context on startup, resume, clear and compact:

| The task | What the agent does |
|----------|---------------------|
| a lookup, a typo, a one-line fix | works alone |
| a decision with two defensible options, a root cause, a diff about to ship | loads `peer-chat-bg:peer-chat` |
| an agreed multi-file design | runs `peer-chat-bg:build` |

- 📝 **Text only:** the hook starts no peer. A native background peer is a tool call the
  agent makes when the task reaches the second tier.
- 🎚️ **One marker for both plugins:** the first line is `bg` (this plugin), `agterm` (the agterm
  [peer-chat](../peer-chat/README.md) plugin) or `0`. A missing file, `0` or any other value
  keeps both hooks silent, so the two plugins never fire in the same session.
  `CLAUDE_CONFIG_DIR` moves the file; a `PEER_CHAT_MODE` shell export overrides it for one run.
  A settings.json `env` block never reaches hook processes, so do not set it there.
- 🔇 **Silent in agent-started runs:** when `PEER_CHAT_NAME` is set (a spawned agterm peer),
  when `CLAUDE_CODE_ENTRYPOINT` starts with `sdk` (`claude -p`), and when two or more parent
  processes are named `claude` or `codex` (a `codex exec` started from a Claude session
  inherits `CLAUDE_CODE_ENTRYPOINT=cli`, so env cannot show it). A wrapper named in
  `PEER_CHAT_CLAUDE_COMMAND` or `PEER_CHAT_CODEX_COMMAND` counts as its harness.
- ⚠️ **The check can miss, never invent:** a harness whose process shows under another name
  (`node` for an npm-installed CLI) is not counted, and a headless run started from it gets
  the directive. That costs one paragraph of context and starts nothing.
- 🔐 **Codex approval:** Codex runs a plugin hook only after you approve it, once per machine;
  the approval is stored under `[hooks.state]` in `~/.codex/config.toml`. Until then Codex
  sessions start without the directive.

## 🎛️ Peer model

- 🎛️ **Choose the peer model:** `/peer-chat-bg:peer-chat claude(fable)` in Claude Code or
  `/peer-chat-bg:peer-chat codex(astra)` in Codex. Both discussion and build accept `claude` or
  `codex`, optionally with `(model)` or `:model`; build also accepts `--peer=<value>`.
  The calling agent maps shorthand and states the mapping; scripts pass no model aliases.
- 🧬 **Inherit by default:** without a model, the native child inherits the main session's
  model. A background peer must use the same runtime as its parent; a different runtime is
  refused with a pointer to agterm `peer-chat:peer-chat`.

## ⚙️ State and project configuration

Run `scripts/peer-chat-bg.sh --explain` from the consuming repo. A committed `.peer-chat-bg.json`
may set `state_dir` (default `tmp/peer-chat-bg`) and the answer budgets `stall_minutes` and
`grace_minutes`. Topic state is schema 2 (`<state_dir>/<slug>/state.json`, shared with agterm
`peer-chat`); a schema 1 topic migrates in place on its first mutating command. Keep that directory ignored and private.
The helper prints JSON and uses Python 3, process locks and atomic writes. See the skill for
the init/bind/prepare/receipt/check/finalize lifecycle. It records protocol evidence, not
cryptographic peer authentication, and does not prevent native calls outside the protocol.

## 🛠️ Development

```bash
python3 scripts/sync-peer-chat-shared.py
python3 scripts/sync-peer-chat-protocol.py
python3 scripts/sync-peer-chat-shared.py --check
python3 scripts/sync-peer-chat-protocol.py --check
make test
```

Tests and fixtures live at repository root, never in shipped plugin directories. Keep both
plugin manifests/version changelog entries in sync after shipped changes.
