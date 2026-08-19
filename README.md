# cc-millz

Things that make [Claude Code](https://claude.ai/code) even better — my personal marketplace of independent plugins, by [Millon15](https://github.com/Millon15).

> Structure inspired by [umputun/cc-thingz](https://github.com/umputun/cc-thingz).

This is an unapologetically opinionated set: every plugin here is something I actually use. Even if you don't need my particular toolbox, it may give you ideas for building your own.

---

> ## 🌟 [Other people's plugins I actually use →](RECOMMENDED.md)
>
> Six third-party marketplaces worth a `/plugin marketplace add`: design dialogue, TUI diff annotation, autonomous execution, Codex, engineering skills, PhpStorm.
>
> Deliberately **not** re-exported here — install them upstream and keep their updates.

---

## 🔌 Plugins

| Plugin | Description |
|--------|-------------|
| [🪧 agterm-lanes](plugins/agterm-lanes/README.md) | Self-labelling agterm panes — name, emoji, tint, glyph and reboot-survivable sessions |
| [🤖 codex-delegation](plugins/codex-delegation/README.md) | Codex CLI (gpt-5.6/gpt-5.5) as a second-tier workforce under Claude's orchestration |
| [🧰 essentials](plugins/essentials/README.md) | General-purpose personal skills — code-style, concise-writing, `/e15`, `/tldr`, `/recall` |
| [🐘 phpstorm](plugins/phpstorm/README.md) | PhpStorm MCP as an agent surface — code navigation, inspections, live Xdebug loop |
| [🔁 ralphex-revmux](plugins/ralphex-revmux/README.md) | revmux as ralphex's external reviewer — preflight, one-round-per-iteration glue, two-stage runner, post-run reporter + optimizer |
| [🧰 revmux-kit](plugins/revmux-kit/README.md) | revmux project layer — xhigh-safe config, profile.md template, `sol-*` / `fable-*` rosters |
| [📟 statusline](plugins/statusline/README.md) | Two-line status line — git scopes, context window, loaded skills and MCP, quota and spend |
| [🪆 unslop-kit](plugins/unslop-kit/README.md) | My reply contract as a Russian doll over pstack's unslop — wording pass, then layout pass, loaded by a SessionStart hook |
| [🥔 pstack](https://github.com/cursor/plugins/tree/main/pstack) (mirror) | poteto's pstack, mirrored via `git-subdir` from `cursor/plugins` because upstream ships no Claude Code marketplace — 44 skills + 2 agents, Cursor-authored (model panels and `~/.cursor/rules` do not apply); required by unslop-kit |

Each plugin is independent: install only what you want, in any combination.

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
