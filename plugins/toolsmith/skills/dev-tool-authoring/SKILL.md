---
name: dev-tool-authoring
description: >-
  Use when authoring a new agent dev-tool layer (rule/skill/command/agent/script)
  — the per-layout .tmpl scaffolds, the eight-line authoring checklist, and the
  agent-context conventions (tooling>prose, tables>paragraphs, MUST/NEVER, size
  targets, anti-patterns). Backs /toolsmith:create Phase 4.
---

# Dev-Tool Authoring Scaffolds

> **Purpose**: Ship one `.tmpl` per layer PER LAYOUT, so Phase 4 copies and fills `{PLACEHOLDER}` tokens instead of re-deriving frontmatter from memory. Which directory a layer lands in is the layout's answer, never a literal in this file.

## When to Use

- Authoring a layer during `/toolsmith:create` (Phase 4)
- Hand-authoring a rule, skill, command, agent or script and you want the conformant skeleton

## The three layouts

Ask the adapter once, then read paths off its JSON rather than off this table:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain
```

| Layout | Positive marker | Skills | Commands | Agents | Rules | Sync after a write |
| --- | --- | --- | --- | --- | --- | --- |
| `rulesync` | a `rulesync.jsonc`, `.json`, `.ts`, `.js` or `.mjs` config at the root | `.rulesync/skills/<name>/SKILL.md` | `.rulesync/commands/<category>/<name>.md` | `.rulesync/subagents/<name>.md` | `.rulesync/rules/<name>.md` | run `values.sync_cmd`; it regenerates every directory in `values.generated_dirs`, which are outputs — an edit there is overwritten by the next run |
| `plugin` | `.claude-plugin/plugin.json` or a marketplace manifest | `skills/<name>/SKILL.md` | `commands/<name>.md` | `agents/<name>.md` | — (a plugin has no rules layer) | none: the shipped files ARE the sources |
| `plain` | `AGENTS.md`, `CLAUDE.md`, `.claude/`, `.cursor/` or `.agents/` | `.claude/skills/<name>/SKILL.md` | `.claude/commands/<name>.md` | `.claude/agents/<name>.md` | `.claude/rules/<name>.md` | none: the shipped files ARE the sources |

`values.sync_cmd` is `null` unless the project's profile declares one. Report the sync step as **none** in that case and stop — a fabricated sync command is worse than no sync step.

## Templates

One set per layout, because the frontmatter shape differs; `script.sh.tmpl` is shared, since a script has no frontmatter at all.

| Layer | Scaffold | Lands at | Invariants the linter checks |
| --- | --- | --- | --- |
| Rule | `templates/{layout}/rule.md.tmpl` | `values.rules_dir`/`<name>.md` | line 1 `---`; `> **Purpose**:` first after the title; ≤50 body lines |
| Skill | `templates/{layout}/SKILL.md.tmpl` | `values.skills_dir`/`<name>/SKILL.md` | line 1 `---`; `name` + `description` ("Use when…" — the description is the ONLY discovery surface) |
| Command | `templates/{layout}/command.md.tmpl` | `values.commands_dir`/`<name>.md` | line 1 `---`; phases + a Guardrails section |
| Agent | `templates/{layout}/agent.md.tmpl` | `values.agents_dir`/`<name>.md` | line 1 `---`; `name` + `description` carrying when-spawned and Keywords |
| Script | `templates/script.sh.tmpl` | wherever the project keeps executables | relative paths only; a stated exit-code contract |

`values.rules_dir` and `values.agents_dir` are `null` where the layout has no such layer — say so and drop the layer rather than inventing a directory for it.

## Usage

0. **Search first**: load `toolsmith:skill-discovery` and run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" "<what it does>" --remote`. An existing plugin, marketplace or public skill beats a new one — this is `/toolsmith:create` Phase 0 in full.
1. Copy the scaffold for the layer, from the set matching `values.layout`, to the path the adapter reports.
2. Replace every `{PLACEHOLDER}` token.
3. Lint it: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-dev-tool.sh" <file>` — fix each warning before the next layer.
4. After all layers: run `values.sync_cmd` when the layout has one, otherwise nothing regenerates and the files are already live.

## The eight-line authoring checklist

Apply this to every layer body. It is the fallback when no companion authoring skill is in the session, and the summary of one when there is:

1. **Invocation model** — state who invokes the layer and when: a user typing a command, a model matching a description, a hook firing on an event.
2. **Description as triggers only** — the description carries the phrases a future session would type. Not a summary of the body.
3. **Information hierarchy** — the thing a reader needs first goes first; background goes last or into a reference file.
4. **Pruning** — cut anything a competent agent already knows. Every retained line has to earn its tokens against the user's actual task.
5. **Leading words** — begin each bullet, row and heading with the word a scanner searches for, not with an article or a preamble.
6. **Completion criteria** — say how the reader knows the step is done: a command's exit code, a file that now exists, a check that passes.
7. **No negation as the only instruction** — "NEVER X" needs the "do Y instead" beside it, or the reader is left without a path.
8. **Single source of truth** — one fact lives in one layer. Cross-reference the other layers instead of restating it.

## Authoring style (agent-context conventions)

Standards for files read by agents rather than humans — every layer above, plus the project's root instruction file.

**Principles**: Tooling > prose (commands, paths, exit codes > architecture descriptions) · Tables > paragraphs · MUST/NEVER > should/consider · Omit the obvious (agents know language syntax, HTTP verbs, git basics) · Shorter = better (every token competes with the user task).

**Size targets**:

| Type | Max lines | If exceeded |
| --- | --- | --- |
| Rule | 50 (soft cap) | Split, or convert to a skill plus a short routing rule |
| Root instruction-file section | 20 | Move the detail into a skill |
| Skill description | 4 lines | Shorten |

**Anti-patterns**: Architecture overviews in always-loaded files · code style guides as rules · duplicating the README in the root instruction file · a long example where a table row suffices · a `## Related Documentation` footer in an agent-context file (that convention belongs to human docs; the linter flags it) · a real ticket reference in body prose to explain WHY a constraint exists — that belongs in the commit message, and the only allowed use is as a format placeholder such as `ABC-1234`.
