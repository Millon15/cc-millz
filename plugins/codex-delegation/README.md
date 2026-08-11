# 🤖 codex-delegation

    /plugin install codex-delegation@cc-millz

Uses the Codex CLI as a second-tier workforce: Claude remains the orchestrator and taste owner, while Codex handles bulk work, second opinions, and independent verification.

⚠️ **Depends on** the `codex` CLI and the official [codex-plugin-cc plugin](https://github.com/openai/codex-plugin-cc) (`/plugin install codex@openai-codex`, then `/codex:setup`).

Official Codex plugin implementations always take precedence: reviews, implementation handoffs, and diagnosis route through the official `/codex:review`, `/codex:adversarial-review`, and `codex:codex-rescue`. This plugin only adds the lanes the official one does not cover.

## Core ideas

- **gpt-5.6** (`gpt-5.6-sol`, the Codex config default) is the top tier — use it for reviews, hard diagnosis, and substantial implementation work.
- **gpt-5.5** is the bulk/mechanical tier — clear-spec implementation, data analysis, and migrations.
- **Codex output is evidence, not authority** — Claude verifies Codex findings against the actual code before relaying them or declaring work done.
- **Independent runtime verification** — Codex can act as a separate local agent that launches the app, drives the UI in a browser or simulator, captures screenshots, and reports pass/fail with actionable feedback (see `codex-computer-use` below).

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `codex-delegation:codex-delegate` | 🧭 Routing brain — maps intent to the right plugin command or agent, carries the model rubric (gpt-5.6 = top tier, gpt-5.5 = bulk), preflight checks, and the verification stance |
| skill | `codex-delegation:codex-workflow-fanout` | 🔀 Pattern for gpt workers inside Workflow/Agent fan-outs — thin wrapper agents, `gpt-5.6:` labels, worktree isolation, timeout/background rules |
| skill | `codex-delegation:codex-computer-use` | 🖥️ Independent UI/runtime verification via `codex exec` — browser automation, simulators, app launching, screenshots, structured pass/fail/blocked reports |
| agent | `codex-workflow-worker` | 📦 Spawnable thin wrapper — one self-contained Codex task per spawn; returns the report and never solves the task itself |

---

Part of [cc-millz](../../README.md).
