# cc-millz

Things to make [Claude Code](https://claude.ai/code) even better — my personal marketplace of independent plugins, by [Millon15](https://github.com/Millon15). Structure inspired by [umputun/cc-thingz](https://github.com/umputun/cc-thingz).

Unapologetically opinionated: every plugin here is something I actually use. If you don't need my toolbox, it may still give you ideas for building your own.

## 📦 Install

Add the marketplace, then install the plugins you want:

    /plugin marketplace add Millon15/cc-millz

    /plugin install codex-delegation@cc-millz
    /plugin install essentials@cc-millz

- 🧪 **Test locally**: `claude --plugin-dir plugins/codex-delegation` (+ `/reload-plugins` in-session)
- 📌 **Or pin in a repo's versioned `.claude/settings.json`** (team-shared repos: only non-personal plugins!):

```json
{
  "extraKnownMarketplaces": {
    "cc-millz": { "source": { "source": "github", "repo": "Millon15/cc-millz" } }
  },
  "enabledPlugins": { "codex-delegation@cc-millz": true }
}
```

## 🔄 Updating

- ✅ `/plugin` → **Marketplaces** → **Update marketplace** — reliable path, pulls latest catalog
- ⚠️ `/plugin` → **Installed** → **Update now** — local cache, can be stale; fallback only
- 🤖 **Enable auto-update**: `/plugin` → Marketplaces → Enable auto-update (refreshes each session start)

## 🔌 Plugins

| Plugin | Description |
|--------|-------------|
| [🤖 codex-delegation](#-codex-delegation) | Codex CLI (gpt-5.6/gpt-5.5) as second-tier workforce under Claude's orchestration |
| [🧰 essentials](#-essentials) | General-purpose personal skills — code-style and friends |

### 🤖 codex-delegation

Use Codex CLI as a second-tier workforce: Claude stays orchestrator + taste owner, Codex takes bulk work, second opinions, and independent verification.

> ⚠️ **Depends on** the official [openai-codex plugin](https://github.com/openai/codex-plugin-cc) (`/plugin install codex@openai-codex` → `/codex:setup`) and the `codex` CLI. Plugin implementations always win — review/implementation/diagnosis route through `/codex:review`, `/codex:adversarial-review`, `codex:codex-rescue`; this plugin only adds the missing lanes.

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `codex-delegation:codex-delegate` | 🧭 Routing brain — intent → plugin command/agent table, model rubric (gpt-5.6 = top tier, gpt-5.5 = bulk), preflight, verification stance |
| skill | `codex-delegation:codex-workflow-fanout` | 🔀 gpt workers inside Workflow/Agent fan-outs — thin wrapper agents, `gpt-5.6:` labels, worktree isolation, timeout/background rules |
| skill | `codex-delegation:codex-computer-use` | 🖥️ Independent UI/runtime verification via `codex exec` — browser, simulators, screenshots |
| agent | `codex-workflow-worker` | 📦 Spawnable thin wrapper — ONE self-contained Codex task per spawn, report back, never solves the task itself |

Core ideas:

- 🥇 **gpt-5.6** (`gpt-5.6-sol`, Codex config default) = top tier, Fable-5 analogue — reviews, hard diagnosis, substantial implementation
- 🚚 **gpt-5.5** = bulk/mechanical tier — clear-spec implementation, data analysis, migrations
- 🔍 **Codex output = evidence, not authority** — Claude verifies findings against code before relaying

### 🧰 essentials

General-purpose personal skills. My taste — default to **user-scope** install; enabling in a team repo's versioned settings is a deliberate owner decision (I do it in mine).

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `essentials:code-style` | 🎨 Personal code taste — declarative orchestrators + small intent-named helpers (SLAP), flat control flow, no narrating comments, typed VOs, fail-fast; decoded DRY/YAGNI/KISS/SOLID + patterns-to-reach-for menu |

Load before writing or refactoring any production code so the output matches the owner's style.
