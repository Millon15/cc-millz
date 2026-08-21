---
description: >
  Review an existing agent dev tool without changing it — lint every file of the
  tool against the layout's conventions, judge the design against the standards
  /toolsmith:create applies, and report any tool that now duplicates it. Writes
  nothing.
argument-hint: <tool-name>
disable-model-invocation: true
---

# `/toolsmith:check`

A conformance pass over a tool that already exists. Read-only from start to finish: every finding is a line in the report, never an edit.

## Phase 0 — Resolve the layout (ALWAYS FIRST)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain
```

| JSON key | What it decides |
| --- | --- |
| `values.layout` | which conventions the tool is judged against |
| `values.skills_dir` · `commands_dir` · `agents_dir` · `rules_dir` | where this tool's files are looked for; `null` means the layout has no such layer |
| `values.generated_dirs` | copies to compare against, never files to judge |
| `values.sync_cmd` | named in a finding when a source file is newer than its generated copy |

Exit 2 means no layout marker or an unreadable profile — STOP and print the script's own message.

## Input

`$ARGUMENTS` is the tool name. Empty → list the tools found under the layer directories and ask which one.

## Phase 1 — Collect the tool's files

Look for, under the directories Phase 0 reported:

| Layer | Looked for at |
| --- | --- |
| Command | `values.commands_dir`, any depth, basename `<tool>.md` |
| Skill | `values.skills_dir`/`<tool>/SKILL.md`, plus every sibling in that directory |
| Agent | `values.agents_dir`/`<tool>.md` |
| Rule | `values.rules_dir`/`<tool>.md`, and any routing rule named after it |

No file matches → say so and stop. A tool that is not there is not a conformance finding.

## Phase 2 — Lint each file

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-dev-tool.sh" --audit <file>
```

Collect the `AUDIT CONFORMANT` / `AUDIT REPORT` line per file. The linter never blocks and never edits; its output is evidence for the report.

## Phase 3 — Judge the design

Beyond what a linter can see, ask of each layer:

| Question | Failing looks like |
| --- | --- |
| Does the description carry the trigger phrases a future session would type? | a description that summarises the body |
| Is the layer count justified? | a rule and a skill saying the same thing |
| Do its skill and command references resolve to things that exist? | a reference to a retired tool, or to a plugin skill under a name this layout does not expose |
| Is an always-loaded rule still worth its tokens? | reference material living in a rule |
| Is the tool reachable? | present in the sources but missing from the generated copies, which means the sync has not run |
| Does it still do one thing? | a command that grew a second lifecycle inside itself |

## Phase 4 — Duplicate check

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" "<the tool's own description>" --remote
```

Report any non-self hit that outranks it as "possible duplicate of `<x>`". Report only — the decision to merge, retire or keep is the user's, and `/toolsmith:retire` is where a removal happens.

## Phase 5 — Report

One report, then stop:

```
tool: <name> · layout <values.layout> · <n> file(s)

| File | Layer | Verdict | Findings |
| --- | --- | --- | --- |
| <path> | skill | CONFORMANT | — |
| <path> | command | REPORT | <one line per finding> |

design: <the Phase 3 answers that failed, one line each>
duplicates: <hit + why it outranks, or "none">
```

## Guardrails

- MUST write nothing — no edit, no fix, no sync, no deletion. `/toolsmith:create` edits; `/toolsmith:retire` deletes.
- MUST judge against the layout Phase 0 reported, never against another project's shape.
- MUST report a possible duplicate rather than acting on it.
- NEVER treat a linter warning as a blocker: the linter always exits 0 and the verdict is the report's.
- NEVER read a generated copy as the tool's source; the sources are the layer directories.
