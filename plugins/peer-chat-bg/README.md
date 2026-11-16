# 🗣️ Background peer chat

An equal coding peer without agterm: one plugin for Claude Code's native background agents
and Codex's native collaboration tools. `/peer-chat-bg:peer-chat` discusses or reviews;
`/peer-chat-bg:build` implements an agreed design through accepted lanes, frozen cross-review
targets and recorded acceptance checks.

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
