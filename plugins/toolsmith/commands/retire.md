---
description: >
  Remove an agent dev tool from the one place that owns it — the layout's source
  directories — after listing every file it would delete and getting a yes. Never
  hand-deletes a generated copy, and never leaves a same-named stub behind.
argument-hint: <tool-name>
disable-model-invocation: true
---

# `/toolsmith:retire`

Delete a tool from its SOURCES. Under a layout whose agent directories are generated, those copies are pruned by the sync, not by hand.

## Phase 0 — Resolve the layout (ALWAYS FIRST)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain
```

| JSON key | What it decides |
| --- | --- |
| `values.skills_dir` · `commands_dir` · `agents_dir` · `rules_dir` | the only directories a deletion may touch |
| `values.generated_dirs` | copies the sync prunes — NEVER deleted by hand |
| `values.sync_cmd` | the command Phase 4 runs; `null` means the deletion is already complete |
| `values.docs_cmd` | offered in Phase 5 when the profile declares one |

Exit 2 means no layout marker or an unreadable profile — STOP and print the script's own message.

## Input

`$ARGUMENTS` is the tool name. Empty → ask which tool, and never guess from a partial match.

## Phase 1 — List what would go

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-dev-tool.sh" --retire <tool>
```

It is a dry run: it lists and deletes nothing. Add anything it cannot know about — a routing rule named after the tool, a task-runner recipe, a permission entry, a reference from another layer.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" --exact <tool>
```

Run it before the deletion to see every tier that still declares the name, so a caller in another layer is found now rather than after the file is gone.

## Phase 2 — Confirm (HARD GATE)

Show the full list — every path, plus each inbound reference found — and ask for an explicit yes. A deletion is not resumable from a half-answer, so no partial confirmation counts.

## Phase 3 — Delete

- Under version control: `git rm` each listed path, so the removal is recorded rather than merely absent.
- Delete the whole skill directory, not just its `SKILL.md`: a bundle sibling left behind is a file nothing owns.
- NEVER leave a same-named stub explaining where the tool went. A stub still ranks in every search, still costs context, and still answers to the name.
- NEVER delete anything inside `values.generated_dirs`.

## Phase 4 — Sync

Run `values.sync_cmd`. It prunes the generated copies of what was just deleted. Where it is `null`, report "sync: none — the sources were the only copies" and continue.

Then confirm the name is gone: re-run the `--exact` check from Phase 1 and expect `NAME FREE` for every local tier.

## Phase 5 — Sweep the callers

1. Search the project for the tool's invocation — the command name, the skill name, the script path — and fix or remove each hit. A dangling reference in another layer is the failure mode this phase exists for.
2. Run `values.docs_cmd` when the profile declares one, so the documentation stops advertising a tool that is gone. Where it is `null`, skip and say so.
3. Report: files deleted, references swept, sync run or skipped.

## Guardrails

- MUST list before deleting, and MUST get an explicit yes.
- MUST delete only under the layout's source directories.
- MUST use the version-control removal where the project is under version control.
- NEVER hand-delete a generated copy — the sync prunes them.
- NEVER leave a same-named stub, a placeholder, or an empty directory.
- NEVER retire a tool while a caller in another layer still names it: sweep first, or fix the caller in the same change.
