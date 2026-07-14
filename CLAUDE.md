# CLAUDE.md

Guidance for Claude Code in this repo.

## Repository Purpose

Millon15 personal Claude Code plugin marketplace — skills, agents, (future) hooks/commands as independent plugins. Structure modeled after umputun/cc-thingz.

## Key Rules

- **README.md stays current** — new plugin/skill/agent/script/config → update README (TOC table + plugin section) same change.
- **README style sacred**: emoji-prefixed titles + main list items, lists over prose, concise per-plugin sections, TOC table with anchor links.
- MIT-licensed. Personal project by Millon15.
- **No machine-specific paths** in shipped plugin content — use `${CLAUDE_PLUGIN_ROOT}` inside skills/hooks (plugin files copied to cache dir on install; relative paths break). Exception: openai-codex plugin cache refs resolved by Glob at runtime, documented in skills.
- **Personal-taste plugins (essentials) default to user scope** — enabling in a project's versioned settings is a deliberate repo-owner decision, never a silent default.

## Conventions

- **Versioning** — per-plugin `version` in `plugins/<name>/.claude-plugin/plugin.json`, independent semver: patch = fix, minor = new component, major = breaking. Bump on ANY change to shipped plugin content, not just `.claude-plugin/` files.
- **Changelog** — bump ⇒ update `CHANGELOG.md` same change; headings `## <plugin> v<version> - YYYY-MM-DD`.
- **Cross-references** — skills referencing skills in same plugin use plugin prefix (e.g. `codex-delegation:codex-delegate`); other plugins by own prefix.
- **Dependency** — codex-delegation requires `codex@openai-codex` (marketplace `openai/codex-plugin-cc`) + `codex` CLI; skills preflight for companion script, stop with install instructions when missing.

## Structure

- `.claude-plugin/marketplace.json` — marketplace catalog
- `plugins/codex-delegation/` — Codex CLI second-tier delegation (3 skills + 1 agent)
- `plugins/essentials/` — general-purpose personal skills (code-style)

## Local Plugin Development

- Test locally: `claude --plugin-dir plugins/<name>`; `/reload-plugins` in-session picks up file changes.
- Installed copies read from plugin cache — publishing = commit + push, then `/plugin` → Marketplaces → Update marketplace (reliable path; Installed → "Update now" cache can lag).