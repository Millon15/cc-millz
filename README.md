# cc-millz

Personal Claude Code plugin marketplace by [Millon15](https://github.com/Millon15). Structure modeled after [umputun/cc-thingz](https://github.com/umputun/cc-thingz).

## Install

```
/plugin marketplace add Millon15/cc-millz
/plugin install codex-delegation@cc-millz
```

Or in a repo's versioned `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "cc-millz": { "source": { "source": "github", "repo": "Millon15/cc-millz" } }
  },
  "enabledPlugins": { "codex-delegation@cc-millz": true }
}
```

## Plugins

### codex-delegation

Use Codex CLI (gpt-5.6 / gpt-5.5) as a second-tier workforce under Claude's orchestration.

**Depends on the official [openai-codex plugin](https://github.com/openai/codex-plugin-cc)** (`/plugin install codex@openai-codex`, then `/codex:setup`) and the `codex` CLI itself. Plugin implementations always win: review/implementation/diagnosis route through `/codex:review`, `/codex:adversarial-review`, and the `codex:codex-rescue` agent — this plugin only adds what the official one lacks:

| Component | What it adds |
| --- | --- |
| `codex-delegate` skill | Routing brain: intent → plugin command/agent table, model rubric (gpt-5.6 = top tier, gpt-5.5 = bulk), preflight, verification stance |
| `codex-workflow-fanout` skill | Pattern for gpt workers inside Workflow/Agent fan-outs (thin wrapper agents, `gpt-5.6:` labels, worktree isolation, budget notes) |
| `codex-computer-use` skill | Independent UI/runtime verification via `codex exec` (browser, simulators, screenshots) |
| `codex-workflow-worker` agent | Spawnable thin wrapper: one self-contained Codex task per spawn, report back |

## License

MIT
