---
name: skill-discovery
description: >-
  Use when deciding whether a capability already exists before authoring a new
  skill, command, or agent — "is there a skill for X", "find a skill", "does a
  plugin already do this", "what should I install for X", or any
  /toolsmith:create Phase 0 reuse check. Carries the search ladder (project,
  user, installed plugins, marketplaces, skills.sh, GitHub), the quality rubric,
  and the adoption table that turns a hit into an installed or vendored tool.
---

# Skill Discovery

> **Purpose**: Search before you build. Most capabilities already exist in an installed plugin, a marketplace clone, or a public skills repo — authoring a duplicate costs context on every session forever.

## When to Use

- `/toolsmith:create` Phase 0, before any layer is authored
- "is there already a skill for X" · "find me a skill that does X" · "which plugin covers X"
- Naming a new tool — `--exact` is the collision check
- Deciding whether a capability is worth a project skill or an upstream install

## Where this project keeps its layers

Nothing below names a directory. The layout adapter answers that, once, from a positive marker at the project root:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain
```

| Layout | Positive marker | Skills | Commands | Agents | Rules | Sync after a write |
| --- | --- | --- | --- | --- | --- | --- |
| `rulesync` | a `rulesync.jsonc`, `.json`, `.ts`, `.js` or `.mjs` config at the root | `.rulesync/skills/<name>/SKILL.md` | `.rulesync/commands/<category>/<name>.md` | `.rulesync/subagents/<name>.md` | `.rulesync/rules/<name>.md` | run `values.sync_cmd`; it regenerates every directory in `values.generated_dirs`, which are outputs — never author there |
| `plugin` | `.claude-plugin/plugin.json` or a marketplace manifest | `skills/<name>/SKILL.md` | `commands/<name>.md` | `agents/<name>.md` | — | none: the shipped files ARE the sources |
| `plain` | `AGENTS.md`, `CLAUDE.md`, `.claude/`, `.cursor/` or `.agents/` | `.claude/skills/<name>/SKILL.md` | `.claude/commands/<name>.md` | `.claude/agents/<name>.md` | `.claude/rules/<name>.md` | none: the shipped files ARE the sources |

The adapter reports the same paths as `values.skills_dir`, `values.commands_dir`, `values.agents_dir` and `values.rules_dir`, so a caller reads them rather than the table. `values.sync_cmd` is `null` where the project declared none — report the sync step as **none** and stop, never invent a command.

## The ladder

Climb only as far as you need. Each rung costs more than the one above it.

| Rung | Source | How | Cost |
| --- | --- | --- | --- |
| L0 | The skill list already in this context window | Read it. It lists every enabled project + plugin skill by description | free |
| L1 | This project's own layer directories | `find-skill.sh "<query>" --tier project` | ~1s |
| L2 | `~/.claude/skills` + every installed plugin | same, `--tier user,installed` | ~2s |
| L3 | Marketplace clones not installed + the official catalog | same, `--tier marketplace` | ~2s |
| R | skills.sh search API + `gh search code --filename SKILL.md` | same, `--remote` | 5-15s, network |
| R+ | grep.app and Context7, model-side | see below | one MCP call each |

Default run covers L1-L3 in one shot:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" "refund webhook retry" --remote
```

L0 is not optional and not in the script — the in-context list is the cheapest hit you will get, and it is the only rung that knows what is enabled *right now*.

## Model-side remote tools

The script covers skills.sh and `gh search code`. These two are MCP tools, so they stay with you — and each is optional: when the server is not in the session, say so in one line and rely on the script's remote tier rather than skipping the rung silently.

- `grep.app` (`searchGitHub`) — literal match, not semantic. Search a distinctive phrase, never a question, with `path: "SKILL.md"` and `language: ["Markdown"]`. Results are heavy with mirrors (`davila7/claude-code-templates`, `*-zh` forks, vendored copies under `eval/`): dedupe by skill-dir basename plus description, then prefer a repo in `references/known-sources.json`.
- Context7 (`resolve-library-id`) — ONLY when the tool wraps a named library, framework, or CLI. It finds that library's own docs or skills repo (e.g. `microsoft/skills`, `upstash/context7`). Not a skills registry.

NEVER run `ctx7 skills search` or `ctx7 skills install`: the CLI prints "Skill commands are deprecated and will stop working in the next major release" and only renders an interactive picker, which hangs a non-interactive session.

`npx skills find` is the human-facing twin of the script's remote tier and hits the same API. Prefer the script — it needs no network round trip through npx.

## Quality rubric

Judge a remote hit before proposing it:

| Signal | Strong | Caution |
| --- | --- | --- |
| Installs (skills.sh) | ≥1K | <100, or absent |
| Source | `references/known-sources.json`, or the tool vendor's own org | an unknown personal repo |
| Freshness | commits in the last few months | untouched for a year |
| Token cost | `claude plugin details <plugin>@<marketplace>` — read always-on vs on-invoke | a plugin adding >2K always-on tokens for one skill you want |
| License | present | absent, if the skill will be vendored |

A plugin's always-on cost is paid by every session, forever. A 20-skill plugin installed for one skill is usually the wrong trade — vendor the one skill, or write a thin wrapper.

## Adoption table

Every hit lands in exactly one row.

| Found where | Adopt how |
| --- | --- |
| In context, or already in one of this project's layer directories | Reuse it. Extend that file rather than author a sibling |
| Installed plugin, enabled for this project | Reuse. Reference it as `<plugin>:<skill>` |
| Installed plugin, NOT enabled here | Add it to `enabledPlugins` in the project's Claude settings, then run `values.sync_cmd` when the layout has one. Heavy plugins (many skills, high always-on cost): ASK the user to enable it through `/plugin` — NEVER enable one yourself |
| Installed plugin skill that is locked (`disable-model-invocation`) | Unlock it only where a project rule makes it mandatory — each unlock costs context every turn. A `rulesync` project records the unlock in its plugin classification file; elsewhere the user unlocks it through `/plugin` |
| Marketplace clone, not installed | `claude plugin install <plugin>@<marketplace> --scope project`, then the enable row |
| Marketplace not configured yet | `claude plugin marketplace add <owner>/<repo>` first, then install |
| A GitHub skill that is not a plugin | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/vendor-skill.sh" <owner/repo@skill>` — copies it into `values.skills_dir` and records provenance in `values.vendor_registry` |
| An upstream skill we only want to read, not own | Point at the marketplace clone and `Read` it live |
| Genuinely nothing fits | Author it with `/toolsmith:create`. Record the prior art you considered in the design, so the next session does not redo this search |

## Naming

Before authoring, check the name across every local tier:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" --exact <proposed-name>
```

`NAME TAKEN` means a future `/<name>` or `Skill(<name>)` is ambiguous — pick another. The check compares a bare needle against names written the way they are INVOKED, so `/man` and `<plugin>:<name>` both count as taken.

## Reading the output

| Column | Meaning |
| --- | --- |
| `tier` | which rung produced the hit |
| `origin` | a project layer directory, `<plugin>@<marketplace>`, or `<owner>/<repo>` |
| `status` | `staged` (a plugin copy the project's sync rewrites — never edit it) · `enabled:project` / `enabled:user` / `installed-only` / `not-installed` / `catalog` · `locked` |
| `score` | lexical rank, rarity-weighted. Compare within a tier, not across |

A `staged` project hit and an `installed` hit with the same name are ONE tool seen twice — the staged copy exists so non-Claude agents get it.

The script never installs, enables, or writes anything. Every adoption step is a separate, deliberate action.

Authoring conventions and the per-layout scaffolds: `toolsmith:dev-tool-authoring`.
