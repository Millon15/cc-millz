# 🛠 toolsmith

    /plugin install toolsmith@cc-millz

Four commands for the lifecycle of an agent dev tool — a skill, a command, a subagent, a rule, a script or a hook. `/toolsmith:create` authors one, `/toolsmith:check` reviews one without touching it, `/toolsmith:retire` removes one from the single place that owns it, and `/toolsmith:man` prints tldr-style help for anything already installed.

None of them names a directory. A layout adapter resolves where this project keeps its layers, from a positive marker at the root, and every command reads the answer off its JSON.

## Core ideas

- **Three layouts, each chosen by a positive marker** — a `rulesync` config file, a plugin manifest, or any agent-config marker (`AGENTS.md`, `CLAUDE.md`, `.claude/`, `.cursor/`, `.agents/`). No layout is the fallback: an unmarked directory exits 2 with a message naming every marker it looked for, because a guessed directory is worse than a usage error.
- **The layout is always detected, never declared** — a `layout` or path key placed in `.toolsmith.json` is deliberately ignored, so a repo that changes shape is right on the next run rather than on the next edit. The profile carries only what nothing could detect: the sync command, the docs command, the knowledge skill, the task-runner ladder.
- **Search before you build** — the reuse gate is the first phase of `/toolsmith:create`, over five tiers: this project, the user's own skills, every installed plugin, marketplace clones, and the public ecosystem (skills.sh plus GitHub code search). A duplicate skill costs context in every session forever.
- **`--exact` compares invocations, not strings** — a declared name is written the way it is invoked (`/man`, `<plugin>:<name>`) while the needle is bare. Compared raw, an owned name reads as free.
- **The linter never blocks** — `validate-dev-tool.sh` always exits 0 and reports its findings as context. A gate that fails the build for a line-count warning gets bypassed, and then it is not a gate.
- **Companion skills are soft** — the design dialogue and the authoring standard each use a better companion skill when the session has one, and a full inline fallback when it does not. The plugin's `dependencies` field is empty on purpose.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| command | `/toolsmith:create <name or description>` | 🛠 Author a tool — reuse search, design dialogue, per-layout scaffolds, lint per layer, collision check, sync |
| command | `/toolsmith:check <tool>` | 🔍 Read-only conformance review of an existing tool, plus a duplicate report |
| command | `/toolsmith:retire <tool>` | 🗑 List, confirm, delete from the sources only, sync, then sweep the callers |
| command | `/toolsmith:man [<name> \| <question>]` | 📖 tldr card for any command, skill, agent or rule — or an answer to a project question |
| skill | `toolsmith:skill-discovery` | The search ladder, the quality rubric and the adoption table that turns a hit into an installed or vendored tool |
| skill | `toolsmith:dev-tool-authoring` | Per-layout `.tmpl` scaffolds, the eight-line authoring checklist, the agent-context conventions |
| script | `scripts/toolsmith.sh --explain` | The layout adapter: layout, root, layer directories, registries, and the four profile keys, each with a source |
| script | `scripts/find-skill.sh` | The five-tier skill finder, ranked, with an `--exact` collision mode |
| script | `scripts/validate-dev-tool.sh` | Non-blocking dev-tool linter; `--audit` and `--retire` modes back the other two commands |
| script | `scripts/vendor-skill.sh` | Copies a public GitHub skill into this project's skills directory, with provenance |

## Configuration

A committed `.toolsmith.json` at the project root. Every key is optional, and the file carries ONLY what no marker could reveal.

```json
{
  "sync_cmd": "make agents",
  "docs_cmd": "/docs:refresh",
  "knowledge_skill": "domain-knowledge",
  "task_runner": ["just", "make"]
}
```

| Key | Default when absent |
| --- | --- |
| `sync_cmd` | `null` — the commands report the sync step as "none" rather than inventing one |
| `docs_cmd` | `null` — the docs step is skipped and said to be skipped |
| `knowledge_skill` | `null` — a project question is answered from what is readable, never from an invented owner |
| `task_runner` | the build files at the root, in a fixed order (`detected:build-files`), else an empty ladder |

Layout, root, the four layer directories, `generated_dirs`, `vendor_registry` and `staged_registry` are never read from this file.

    scripts/toolsmith.sh --explain [--root <dir>]

## Recommended companions

Neither is a dependency, and neither is installed by this plugin. Each command works without them and says which path it took.

| Companion | What it improves | Fallback when absent |
| --- | --- | --- |
| a grilling skill, e.g. [`mattpocock-skills:grilling`](https://github.com/mattpocock/skills) | the `/toolsmith:create` Phase 3 design dialogue — one question at a time, to its own completion criteria | the same five questions asked inline, in one round |
| a companion authoring skill, e.g. [`mattpocock-skills:writing-great-skills`](https://github.com/mattpocock/skills) | the Phase 4 authoring standard — the fuller treatment of invocation model, hierarchy and pruning | the eight-line checklist carried in `toolsmith:dev-tool-authoring` |
| a compression skill | the optional Phase 6 pass over each newly authored file | the step is skipped silently |

## Provenance

Extracted from a private monorepo.

---

Part of [cc-millz](../../README.md).
