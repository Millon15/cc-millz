---
name: codex-workflow-fanout
description: Pattern for Codex workers inside Claude Workflow scripts and Agent fan-outs. The model parameter takes Claude models only, so a gpt worker is a thin Claude agent that starts a tracked `codex-job` and hands back its handle, and the parent collects every handle. Use when a workflow or parallel task set should be executed by Codex instead of Claude subagents.
---
# Codex Workflow Fan-out

`Agent` and `Workflow` take Claude models only. A gpt worker is the `codex-delegation:codex-workflow-worker` agent: it
STARTS one tracked job through `${CLAUDE_PLUGIN_ROOT}/scripts/codex-job.sh` and returns its handle. The parent owns
every handle until it is collected and disposed. Probe first (`codex-delegation:codex-delegate` § Availability).

## Lifecycle

```text
[prepared] ──spawn──▶ [starting] ──▶ [running] ──collect──▶ [completed | failed]
                                         │            └── stop or result unprovable ──▶ [uncertain]
                                         └──cancel, stop observed──▶ [cancelled]
```

Three fields, never merged: `lifecycle` (above), `verdict` `pass|fail|blocked|unknown` (the task's own result, from
its validated report), `disposition` `pending|accepted|rejected` (the parent's decision, written by `dispose`).

## Steps

1. Run dir: `<main checkout>/tmp/codex-runs/<slug>/`, passed as `--run-dir` on every record verb. It holds the
   records the parent trusts, so Codex must never be able to write it: a `workspace-write` job runs with `--cwd` its
   own worktree, and the adapter refuses a run dir under that cwd, `/tmp` or `$TMPDIR`. A writable root added in
   Codex's own config is beyond that check and must not contain the run dir or the adapter and companion scripts. A read-only job may share the
   checkout; a run dir inside it must be gitignored.
2. One brief per job, written to a file, passed as `--prompt-file`; never a prompt in a shell argument. One goal per
   brief.
3. Invocation id: stable and derived from the task (`<slug>-<lane>`), so a retried `start` returns the same job.
4. Start: spawn one worker per brief, label `codex:<task>`, in parallel. Each spawn prompt names the adapter path
   `${CLAUDE_PLUGIN_ROOT}/scripts/codex-job.sh`, the run dir, the invocation id, the cwd and the brief file. Each
   worker returns the record with `lifecycle`, `invocation_id` and `job_id` at once.
5. Collect: for every handle, the parent runs (or spawns the worker in collect mode for)
   `codex-job.sh collect --run-dir <dir> --invocation-id <id> --wait-seconds 150`. Exit 4 = still running: collect
   again later. Keep each call under 150 s; a subagent's Bash call is moved to the background at 180 s.
6. Write jobs: `--write --sandbox workspace-write --owned <path>...`, each job with `--cwd` its own clean worktree
   (`isolation: 'worktree'`) and the run dir from step 1; the adapter refuses a dirty worktree. After a write fan-out, check the COMBINED tree, not
   each lane alone: one test run over all lanes' changes.
7. Accept or reject each record with `dispose --decision accepted|rejected --reason <why>` (see Accepting).

## The brief

Codex sees none of this conversation. The brief carries the repo path, the goal, constraints (no commit, push, deploy
or global-config edit; preserve unrelated changes), acceptance criteria, owned paths for a write job, the
verification commands, and this closing contract, verbatim:

````text
End your reply with exactly one fenced json block:
```json
{"schema": "codex-report/1", "verdict": "pass|fail|blocked|unknown", "summary": "...",
 "claims": [{"type": "code", "path": "...", "line": 1, "snapshot": "<sha>"},
            {"type": "runtime", "command": "...", "expected": "...", "observed": "...", "exit": 0,
             "evidence_path": "..."}],
 "blocked": [{"operation": "...", "reason": "..."}]}
```
````

The adapter validates that block. A missing or malformed one leaves the verdict `unknown` with the raw output kept;
nobody reconstructs it from prose.

## Accepting

| Record | Parent does |
| --- | --- |
| `completed`, verdict `pass`, receipts check out, no `out_of_scope_paths` | `dispose accepted` |
| `completed`, verdict `fail` or `blocked` | read the report; `dispose rejected`, or a new brief with a new id |
| verdict `unknown` | read `raw_output_path`; never accept on it |
| `running` past the wait budget | collect again, or `cancel` |
| `uncertain` | stays pending; owned paths stay owned; report it, never relaunch the prompt |
| `cancelled` | read the partial diff (`diff_path`) before anyone else writes those paths |

A job's owned paths are released on one of two settled paths: `completed`, collected and disposed; or `cancel`
reported `cancelled` and the partial diff was read. A wait budget is not a cancel: an unfinished job past it may still
edit, so its paths stay owned.

## Labels and accounting

Label workers `codex:<task>`: the workflow UI shows the wrapper's Claude model, so the label is the only truth about
the real worker. `budget.spent()` counts Claude tokens only; Codex work is invisible to it.
