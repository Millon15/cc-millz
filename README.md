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
| [🪧 agterm-lanes](#-agterm-lanes) | Self-labelling agterm panes — name, emoji, tint, glyph and reboot-survivable sessions |
| [🤖 codex-delegation](#-codex-delegation) | Codex CLI (gpt-5.6/gpt-5.5) as a second-tier workforce under Claude's orchestration |
| [🧰 essentials](#-essentials) | General-purpose personal skills — code-style and friends |
| [🐘 phpstorm](#-phpstorm) | PhpStorm MCP as an agent surface — code navigation, inspections, live Xdebug loop |

### 🪧 agterm-lanes

Run more than two Claude Code sessions at once and the sidebar becomes a wall of identical panes. This plugin makes every lane label itself.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal (macOS) — outside it every hook is a silent no-op.

Core ideas:

- **Claude already knows what the session is about** — it auto-titles every conversation. The lane just types a bare `/rename`, reads the new title back, and mirrors it. No extra model call, no cost, no latency.
- **Fires on the first `Stop` *or* the first question** — a turn that asks you something never ends, so it emits no `Stop`. Without the second trigger a session can sit unnamed forever on one unanswered question.
- **Never types into a dialog.** On the question path a prompt is on screen and a Return would answer it, so that path only adopts the auto-title.
- **Hue is state, silhouette is role.** The sidebar glyph's shape encodes what the lane is *for*; its colour stays free for the agent's turn state (active / blocked / completed).
- **A reboot reattaches, not restarts** — each session re-pins its pane's restore command to its own live id, so agterm brings the conversation back instead of a bare shell.

| Component | Trigger | Description |
|-----------|---------|-------------|
| hook | `Stop`, `PreToolUse` | 🪧 `agterm-lane.sh` — names the lane once from Claude's session title, then applies a role emoji, pane tint and sidebar glyph inferred from it |
| hook | `Stop`, `PostToolUse`, `UserPromptSubmit`, `Notification` | 🚦 `agterm-status.sh` — agent-status indicator that replays the lane's glyph on every call, because `--shape` reverts on the next status without it |
| hook | `SessionStart` | 📌 `agterm-pin-resume.sh` — re-pins the pane to `claude --resume <live id>` so a reboot or relaunch reattaches the conversation |

Roles are a decision table — `bug` 🐛, `deploy` 🚀, `review` 🔍, `test` 🧪, `refactor` 🧹, `config` 🔧, `data` 📊, `docs` 📝, everything else 💬. Edit `role_style()` in `scripts/agterm-lane.sh` to taste; `star` is deliberately left unassigned so you can mark a lane by hand.

Tunable via environment: `LANE_TYPE_RENAME` (`0` disables keystroke injection entirely), `LANE_IDLE_MIN_MS`, `LANE_TITLE_WAIT_S`, `LANE_TYPE_RETRIES`, `AGTERM_LANE_STATE_DIR`, `AGTERMCTL`.

> **If you already ran agterm's own agent-status hook installer**, remove its four entries from `~/.claude/settings.json` when installing this plugin — otherwise every status fires twice.

To re-name a lane that has already claimed its name, delete `~/.claude/agterm-lanes/lane-<session_id>`.

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

General-purpose personal skills and everyday commands.

| Component | Trigger | Description |
|-----------|---------|-------------|
| command | `/e15` | 🧒 Re-explain the topic currently under discussion as if to a 15-year-old — simpler language, same facts |
| skill | `essentials:code-style` | 🎨 Personal code taste — declarative orchestrators with small intent-named helpers (SLAP), flat control flow, no narrating comments, typed value objects, fail-fast; decoded DRY/YAGNI/KISS/SOLID principles plus a patterns-to-reach-for menu |

### 🐘 phpstorm

Turns the PhpStorm MCP server into a first-class agent surface. Requires **PhpStorm 2026.2+** with its MCP server enabled.

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `phpstorm:phpstorm-mcp` | 🧭 Tool map for indexed code — `analyze_calls` call hierarchy over grep, symbol/structural search, inspections + quick fixes, refactoring, project metadata, IDE-backed SQL; covers the 2026.2 tool renames |
| skill | `phpstorm:phpstorm-debug` | 🐞 Live Xdebug loop — attach to externally-triggered PHP (Docker, CLI, HTTP), breakpoints with conditions, stack + frame values, expression evaluation, mid-flight state mutation; preflight checklist and the Xdebug features that silently do nothing |
