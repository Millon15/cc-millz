# cc-millz

Things that make [Claude Code](https://claude.ai/code) even better — my personal marketplace of independent plugins, by [Millon15](https://github.com/Millon15).

> Structure inspired by [umputun/cc-thingz](https://github.com/umputun/cc-thingz).

This is an unapologetically opinionated set: every plugin here is something I actually use. Even if you don't need my particular toolbox, it may give you ideas for building your own.

## 📦 Install

Add the marketplace, then install the plugins you want:

    /plugin marketplace add Millon15/cc-millz

    /plugin install essentials@cc-millz
    /plugin install codex-delegation@cc-millz

- **Test locally**: run `claude --plugin-dir plugins/codex-delegation`, and use `/reload-plugins` in-session to pick up file changes.
- **Or pin the plugins in a repo's versioned `.claude/settings.json`** — Claude Code installs everything listed there automatically on the first session in that repository:

```json
{
  "extraKnownMarketplaces": {
    "cc-millz": { "source": { "source": "github", "repo": "Millon15/cc-millz" } }
  },
  "enabledPlugins": { "codex-delegation@cc-millz": true }
}
```

## 🔄 Updating

- `/plugin` → **Marketplaces** → **Update marketplace** — the reliable path; pulls the latest catalog from the repository immediately.
- `/plugin` → **Installed** → **Update now** — uses a local cache that can be stale; treat it as a fallback after updating the marketplace.
- **Enable auto-update**: `/plugin` → Marketplaces → Enable auto-update refreshes the marketplace catalog on each session start.

## 🔌 Plugins

| Plugin | Description |
|--------|-------------|
| [🤖 codex-delegation](#-codex-delegation) | Codex CLI (gpt-5.6/gpt-5.5) as a second-tier workforce under Claude's orchestration |
| [🧰 essentials](#-essentials) | General-purpose personal skills — code-style and friends |

### 🤖 codex-delegation

Uses the Codex CLI as a second-tier workforce: Claude remains the orchestrator and taste owner, while Codex handles bulk work, second opinions, and independent verification.

⚠️ **Depends on** the `codex` CLI and the official [codex-plugin-cc plugin](https://github.com/openai/codex-plugin-cc) (`/plugin install codex@openai-codex`, then `/codex:setup`).

Official Codex plugin implementations always take precedence: reviews, implementation handoffs, and diagnosis route through the official `/codex:review`, `/codex:adversarial-review`, and `codex:codex-rescue`. This plugin only adds the lanes the official one does not cover.

Core ideas:

- **gpt-5.6** (`gpt-5.6-sol`, the Codex config default) is the top tier — use it for reviews, hard diagnosis, and substantial implementation work.
- **gpt-5.5** is the bulk/mechanical tier — clear-spec implementation, data analysis, and migrations.
- **Codex output is evidence, not authority** — Claude verifies Codex findings against the actual code before relaying them or declaring work done.
- **Independent runtime verification** — Codex can act as a separate local agent that launches the app, drives the UI in a browser or simulator, captures screenshots, and reports pass/fail with actionable feedback (see `codex-computer-use` below).

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `codex-delegation:codex-delegate` | 🧭 Routing brain — maps intent to the right plugin command or agent, carries the model rubric (gpt-5.6 = top tier, gpt-5.5 = bulk), preflight checks, and the verification stance |
| skill | `codex-delegation:codex-workflow-fanout` | 🔀 Pattern for gpt workers inside Workflow/Agent fan-outs — thin wrapper agents, `gpt-5.6:` labels, worktree isolation, timeout/background rules |
| skill | `codex-delegation:codex-computer-use` | 🖥️ Independent UI/runtime verification via `codex exec` — browser automation, simulators, app launching, screenshots, structured pass/fail/blocked reports |
| agent | `codex-workflow-worker` | 📦 Spawnable thin wrapper — one self-contained Codex task per spawn; returns the report and never solves the task itself |

### 🧰 essentials

General-purpose personal skills.

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `essentials:code-style` | 🎨 Personal code taste — declarative orchestrators with small intent-named helpers (SLAP), flat control flow, no narrating comments, typed value objects, fail-fast; decoded DRY/YAGNI/KISS/SOLID principles plus a patterns-to-reach-for menu |
