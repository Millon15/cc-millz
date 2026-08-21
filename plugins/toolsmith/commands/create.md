---
description: >
  Author a new agent dev tool — a skill, command, subagent, rule, script or hook —
  in whatever agent-config layout this project uses. Searches what already exists
  before anything is written, runs a design dialogue, fills the scaffolds for this
  layout, lints each layer, checks the name for collisions, and syncs only when the
  project has a sync step.
argument-hint: <tool-name or short description> [--no-remote]
disable-model-invocation: true
---

# `/toolsmith:create`

Build a new dev tool through six phases: reuse search, intent, layer bundle, design, authoring, validation. Nothing below names a directory — Phase 0 resolves the layout and every later phase reads paths off its JSON.

## Phase 0 — Resolve the layout (ALWAYS FIRST)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain
```

| JSON key | What it decides |
| --- | --- |
| `values.layout` | which template set Phase 4 copies from: `rulesync`, `plugin` or `plain` |
| `values.root` | the project root every relative path is written under |
| `values.skills_dir` · `commands_dir` · `agents_dir` · `rules_dir` | where each authored layer lands; `null` means the layout has no such layer |
| `values.generated_dirs` | directories a sync WRITES — outputs, never authoring targets |
| `values.vendor_registry` | where a vendored skill's provenance is recorded |
| `values.sync_cmd` | the command Phase 6 runs; `null` means this project has no sync step |
| `values.docs_cmd` | the docs command Phase 6 offers; `null` means skip the docs step |
| `sources.<key>` | `profile`, `detected:<signal>` or `default` — quote it verbatim when reporting |

- Exit 2 means no layout marker, or an unreadable profile. STOP and print the script's own message: it names every marker it looked for. NEVER guess a directory.
- `values.layout` and the four layer directories are ALWAYS detected. A `layout` or path key placed in `.toolsmith.json` is deliberately IGNORED, so a repo that changes shape is right on the next run rather than on the next edit.

Announce one resolution line before anything is written:

```
layout: {values.layout} ({sources.layout}) · root {values.root} · skills {values.skills_dir} · sync `{values.sync_cmd|none}` ({sources.sync_cmd})
```

## Input

Parse `$ARGUMENTS` for:

- `--no-remote` → skip the remote tier in Phase 0.5 (local tiers only; offline or in a hurry)
- otherwise: a tool name or a short description ("deploy watcher", "release-note generator")
- empty → ask ONE question: what should this tool do?

Reviewing an existing tool is `/toolsmith:check`. Removing one is `/toolsmith:retire`.

## Phase 0.5 — Reuse before build (HARD GATE)

Most capabilities already exist. A duplicate costs context in every future session, so this runs BEFORE any design work.

**Load `toolsmith:skill-discovery`** — it carries the ladder, the quality rubric and the adoption table this phase applies.

1. Derive the query from `$ARGUMENTS`.
2. Read the skill list already in this context window first — it is free, and it is the only source that knows what is enabled right now.
3. Run the finder:

    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" "<query>" --remote
    ```

    `--no-remote` drops the remote tier. Zero hits → re-run ONCE with synonyms (the verb, the noun, the error message a user would type) before concluding nothing exists.
4. Model-side passes the script cannot make, each OPTIONAL: a literal-phrase code search over `SKILL.md` files (grep.app), and — only when the tool wraps a named library or CLI — a library-docs resolve (Context7). A missing MCP server is a one-line note, never a silent skip.
5. Present the ranked table, then take ONE of four decisions with the user:

| Decision | What happens |
| --- | --- |
| **adopt** | Follow the matching row of the `toolsmith:skill-discovery` adoption table (enable a plugin, unlock a skill, install, or vendor), run `values.sync_cmd` when the layout has one, and STOP — no layer is authored |
| **extend** | Open the existing file and continue at Phase 4 on it. No new layer, no new name |
| **create** | Continue to Phase 1. Carry a "Prior art considered" list — what was found, why it does not fit — into the Phase 3 design |
| **stop** | Nothing to build |

NEVER skip to Phase 1 because the search "looked unlikely to find anything" — the search is cheap and the duplicate is not.

## Phase 1 — Intent

Ask, if the arguments do not already answer it:

1. What does this tool do, in one sentence?
2. Who invokes it — a user typing a command, a model matching a description, or a hook firing on an event?
3. What problem does it solve that Phase 0.5 did not already find solved?

Overlap is settled: the user chose **create**. Restate the "Prior art considered" list here so the design answers it.

## Phase 2 — Layer bundle

| Layer | Lands at | Purpose | Size |
| --- | --- | --- | --- |
| Rule | `values.rules_dir` | always-loaded MUST/NEVER constraints | ≤50 body lines |
| Skill | `values.skills_dir` | on-demand domain knowledge, CLI reference, scaffolds | tiered by length |
| Script | the project's executables directory | automation shared across layers | — |
| Command | `values.commands_dir` | a user-invoked multi-step workflow | — |
| Agent | `values.agents_dir` | a specialised autonomous persona | ~100 lines |
| Hook | a script plus an event matcher in the agent's hook config | event-triggered automation | — |

| Need | Create |
| --- | --- |
| An always-on constraint | Rule |
| Domain knowledge, a CLI reference, a decision tree | Skill |
| Executable automation | Script |
| A user-invoked multi-step workflow | Command |
| A specialised autonomous persona | Agent |
| Event-triggered automation | Hook — propose ahead, never auto-build |
| Routing ("when the user says X → invoke Y") | Rule, kept under 20 lines |

- A layer whose directory is `null` in Phase 0's JSON does not exist in this layout. Say so and drop it — never invent a directory for it.
- **Propose-ahead default**: build the smallest bundle that works, and offer the extra layers up front rather than generating them.
- **Rule budget gate**: an always-loaded rule costs every session. Before adding one, count the existing rule files and justify "why a rule, not a skill?". Reference material is a skill.

## Phase 3 — Design dialogue (HARD GATE, SOFT dependency)

Resolve five things before any file is written: **inputs**, **outputs**, **integrations**, **failure modes**, **validation**.

| Situation | How the dialogue runs |
| --- | --- |
| A grilling skill is in the session's skill list (for example `mattpocock-skills:grilling`) | Load it and let it drive the questions one at a time, to its own completion criteria |
| No such skill is available | Ask the five questions INLINE, all five in ONE question round, and wait for the answers |

The five inline questions, verbatim:

1. What inputs does it accept — arguments, flags, stdin, files?
2. What outputs does it produce — stdout shape, files written, exit codes?
3. What existing tools, scripts or services does it integrate with?
4. What are its failure modes, and what does it do on each?
5. How will it be validated — which command, run where, showing what?

Neither path is optional and neither is preferred: the companion skill is a better interview, the inline round is the same five answers. Do NOT proceed to Phase 4 until the dialogue produces a concrete design.

## Phase 4 — Author the layers (SOFT dependency)

**Copy a scaffold, do not re-derive one.** Every layer starts from `toolsmith:dev-tool-authoring`, from the template set matching `values.layout`:

```
${CLAUDE_PLUGIN_ROOT}/skills/dev-tool-authoring/templates/{values.layout}/<layer>.md.tmpl
${CLAUDE_PLUGIN_ROOT}/skills/dev-tool-authoring/templates/script.sh.tmpl
```

Fill every `{PLACEHOLDER}` token. The scaffolds carry the frontmatter shape that layout expects, which is why the set is chosen by `values.layout` and not by taste.

**The authoring standard is soft:**

| Situation | How the body is written |
| --- | --- |
| A companion authoring skill is in the session's skill list (for example `mattpocock-skills:writing-great-skills`) | Load it and follow it — it is the fuller treatment of the same ideas |
| No such skill is available | Apply the eight-line checklist below, which `toolsmith:dev-tool-authoring` carries in full |

The eight-line authoring checklist:

1. **Invocation model** — state who invokes this layer and when.
2. **Description as triggers only** — the description carries the phrases a future session would type, not a summary of the body.
3. **Information hierarchy** — what the reader needs first goes first; background goes last or into a reference file.
4. **Pruning** — cut anything a competent agent already knows.
5. **Leading words** — start each bullet, row and heading with the word a scanner searches for.
6. **Completion criteria** — say how the reader knows a step is done.
7. **No negation alone** — every "NEVER X" carries a "do Y instead" beside it.
8. **Single source of truth** — one fact lives in one layer; cross-reference rather than restate.

**Lint after EACH layer, before starting the next:**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-dev-tool.sh" <the file just written>
```

Surface its `additionalContext` warnings inline — frontmatter on line 1, dangling skill references, line caps, command substitution, absolute home-directory paths, a documentation footer in an agent-context file, a file written into a generated directory. The linter NEVER blocks (it always exits 0); fix the warnings rather than stepping over them.

Per-layer specifics:

- **Rule** — `> **Purpose**:` blockquote first after the title, tables over paragraphs, MUST/NEVER over should/consider, ≤50 body lines.
- **Skill** — the `description` is the only discovery surface; put every trigger phrase in it. Do NOT rely on custom metadata blocks: a generating layout strips them.
- **Script** — relative paths only, a stated exit-code contract, executable bit set. Where the agent keeps a permission allowlist, add the entry for it so the first invocation does not stop for a dialog.
- **Command** — input parsing, numbered phases with explicit gates, a Guardrails section last.
- **Agent** — the `description` states the persona, when it is spawned and what it returns; a leaf agent must not be able to spawn another.
- **Hook** — ONLY when Phase 1 answered "a hook" AND the user accepted the layer. Author the script, then register the event matcher in the agent's own hook configuration.

## Phase 5 — Route

A frequently invoked command earns a short routing rule, when the layout has a rules directory:

```markdown
# {Tool-Name} Workflow

> **Purpose**: Route <tool> requests to `/<command-name>`.

| User says | Action |
| --- | --- |
| "<trigger phrase>" | Invoke `/<command-name>` |
```

Skip this phase for a skill-only or script-only tool, and where `values.rules_dir` is `null`.

## Phase 6 — Validate and sync (HARD GATE)

1. **Re-lint** every authored file with `validate-dev-tool.sh`; confirm each is clean or every warning is addressed.
2. **Name-collision check** — the name has to be unambiguous across every local tier AND the ecosystem:

    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" --exact <tool-name> --remote
    ```

    `NAME FREE` continues. `NAME TAKEN` means a future `/<name>` or `Skill(<name>)` is ambiguous — rename now, while the only cost is a file move. The check compares a bare needle against names written the way they are invoked, so an owned `/<name>` or `<plugin>:<name>` counts as taken.
3. **Sync** — `values.sync_cmd` is the project's own command. Run it. Where it is `null`, report "sync: none — the authored files are already live" and move on; NEVER invent a sync command.
4. **Discoverability** — for a layout with `generated_dirs`, confirm the new tool appears in them after the sync. For the other two, confirm the file is where Phase 0 said it would be.
5. **Frontmatter smoke** — line 1 is `---` and the block parses, for every authored markdown layer.
6. **Script smoke** — run each authored script once with `--help` or no argument: exit 0 plus usage output catches a broken relative path before first real use.
7. **Size check** — a rule body ≤50 lines; a skill that grew past its tier gets split or moved to a reference file.
8. **Compression (conditional)** — where a compression skill is in the session's skill list, run it over each newly authored agent-context file. Where none is, skip silently: this step exists only when the tool for it is present. Run it AFTER the size check, since compression changes the counts the check reads. Never compress a plan, spec, changelog or postmortem.
9. **Docs** — `values.docs_cmd` is the project's own documentation command. Run it when the profile declares one; where it is `null`, skip the step and say so. There is no announcement step and no harvest step: what a project does after a tool ships is the project's, and it says so in its profile or not at all.
10. **Working tree** — confirm the authored files appear and no generated directory does.

Close by telling the user the invocation to try. A freshly authored AGENT is not spawnable in the session that wrote it — the registry is fixed at session start.

## Guardrails

- MUST run Phase 0 first and treat its JSON as authoritative. NEVER hard-code a directory the adapter could have supplied.
- MUST author only under the layout's SOURCE directories. NEVER write into a directory listed in `values.generated_dirs` — the next sync overwrites it.
- MUST complete Phase 0.5 before Phase 1. The reuse search is the gate, not a formality.
- MUST run the Phase 3 dialogue — through a grilling skill when one is available, inline otherwise. NEVER skip it because the design "seems obvious".
- MUST apply the eight-line checklist when no companion authoring skill is in the session. Absence of the companion is never a licence to author unguided.
- MUST run the Phase 6 collision check before declaring the tool done.
- NEVER exceed 50 lines in a rule — split it into a skill plus a routing stub.
- NEVER duplicate content across layers; cross-reference instead.
- NEVER create a layer without a stated need — the minimal bundle is the default.
- NEVER rely on custom skill metadata for discovery; the description is the only surface that survives every layout.
- Use relative paths in every example, and no command substitution in documentation.
