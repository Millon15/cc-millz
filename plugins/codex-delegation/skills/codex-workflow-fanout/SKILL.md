---
name: codex-workflow-fanout
description: Pattern for using Codex gpt-5.6/gpt-5.5 workers inside Claude Workflow scripts and Agent fan-outs — the model parameter only takes Claude models, so gpt workers run through thin Bash wrapper agents calling the openai-codex companion runtime. Use when a workflow/parallel task set should be executed by Codex instead of Claude subagents.
---
# Codex Workflow Fan-out

Gap openai-codex plugin not cover: `Agent`/`Workflow` `model:` accept Claude models only. gpt workers = thin Claude wrapper agents shell to Codex.

## Wrapper pattern

- Spawn wrapper with `model: 'sonnet', effort: 'low'` (or `codex-workflow-worker` agent from plugin) — wrapper writes self-contained Codex prompt, runs via Bash, returns report.
- Runtime: prefer plugin companion — `node <cache>/openai-codex/codex/<ver>/scripts/codex-companion.mjs task [--write] [--background] [--model <m>] [--effort <e>] "<prompt>"` (resolve `<cache>/<ver>` by Glob first). Fallback (companion missing): `codex exec -C <repo> -s workspace-write -o <report> "<prompt>"`.
- Structured results: pass `schema` to wrapper `agent()` call — wrapper parses Codex report into schema.
- Prompt contract: reuse plugin `gpt-5-4-prompting` XML blocks (`<task>`, `<structured_output_contract>`, `<verification_loop>`, `<grounding_rules>`). Self-contained — Codex sees none of Claude conversation.

## Conventions (MUST)

| Rule | Why |
| --- | --- |
| Label wrappers `gpt-5.6:<task>` / `gpt-5.5:<task>` | workflow UI shows wrapper Claude model; label = only truth about real worker |
| Parallel WRITE workers → `isolation: 'worktree'` | codex edits collide in shared checkout |
| Long runs: explicit Bash `timeout` (≤600000) or `--background` + poll report file | codex can exceed Bash 10-min default |
| Read-only analysis → NO `--write` | least privilege |
| One task per Codex run; split bundles | quality drops on multi-goal prompts |

## Model choice

Bulk/mechanical stage → `--model gpt-5.5`. Hard reasoning stage → omit model (config default `gpt-5.6-sol`). Rubric: `codex-delegate` skill.

## Accounting

Workflow `budget.spent()` counts Claude tokens only — Codex work free, invisible to budget. Wrapper tokens (sonnet-low) = only Claude cost per worker.