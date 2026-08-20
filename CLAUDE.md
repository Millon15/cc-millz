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
- **`--explain` contract** — every plugin shipping an entry script under `scripts/` resolves project config the same way and prints it on demand. See below; a new plugin MUST match it rather than invent a shape.

### The `--explain` contract

- `scripts/<plugin>.sh --explain` prints ONE JSON object to stdout, exits 0 on success and 2 on an unreadable or unparseable profile, and has NO side effects.
- Config comes from a committed `.<plugin>.json` at the CONSUMING project's root — never `userConfig`, never a prompt: these are team-shared repo facts.
- Shape: `{"plugin":"<name>","profile_file":"<path>|null","values":{…},"sources":{…}}`.
- EVERY key in `values` MUST have the same key in `sources`. A value with no source is a bug.
- A source is one of three words: `profile`, `detected:<signal>` (name the signal), or `default`.
- Detect nothing and have no honest default → exit 2 with a usage message naming the markers looked for. An unmarked directory is a usage error, never a default.
- Suites assert value AND source through `assert_explain_source <json> <key> <expected-source>` in `tests/helpers.bash`.

### Tests

- Per-plugin suites in `plugins/<name>/tests/` — `*.bats` for shell and command surfaces, `*.test.ts` run under `bun test`.
- Shared bats helpers in `tests/helpers.bash`; harness self-tests in `tests/*.bats`.
- `make test` runs both discovery sets; CI runs the same two on push and pull request.
- A markdown command has no CLI boundary, so its contract is asserted by grepping the shipped body.

## Structure

- `.claude-plugin/marketplace.json` — marketplace catalog
- `plugins/agterm-lanes/` — self-labelling agterm panes (3 hooks, macOS + agterm only)
- `plugins/codex-delegation/` — Codex CLI second-tier delegation (3 skills + 1 agent)
- `plugins/essentials/` — general-purpose personal skills and commands (code-style, /e15)
- `plugins/phpstorm/` — PhpStorm MCP + Xdebug agent surface (2 skills)
- `plugins/ralphex-revmux/` — revmux as ralphex's external reviewer (1 skill + 1 command + 2 agents + scripts)
- `plugins/revmux-kit/` — revmux project layer bootstrap (1 skill + templates)
- `plugins/unslop-kit/` — reply contract over pstack:unslop (1 skill + 1 SessionStart hook)

## Local Plugin Development

- Test locally: `claude --plugin-dir plugins/<name>`; `/reload-plugins` in-session picks up file changes.
- Installed copies read from plugin cache — publishing = commit + push, then `/plugin` → Marketplaces → Update marketplace (reliable path; Installed → "Update now" cache can lag).