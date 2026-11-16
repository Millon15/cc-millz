---
name: codex-delegate
description: Routing brain for delegating work to Codex CLI. Use when the user asks Codex/GPT to review, implement, diagnose, or verify something, when a second independent perspective is wanted, or when an argument should be settled with a Codex peer. Routes through the openai-codex plugin and the tracked `codex-job` adapter, never through hand-rolled codex prompts.
---
# Codex Delegate

Claude orchestrates and owns taste. Codex takes bulk work, second opinions and independent verification. Codex output
is evidence, not authority.

## Law: plugin wins

The openai-codex plugin's commands and agent ALWAYS win. This plugin adds only the lanes the official one lacks
(workflow fan-out, runtime verification), and every one of those lanes runs through ONE adapter:
`${CLAUDE_PLUGIN_ROOT}/scripts/codex-job.sh`, a tracked wrapper over the official companion. Never a bare
`codex exec`, never a hand-run companion call.

## Routing

| Intent | Route |
| --- | --- |
| Review local changes, a branch, a commit | `/codex:review` |
| Review with a custom focus or an adversarial stance | `/codex:adversarial-review` |
| Implementation, bugfix, diagnosis, research handoff | `codex:codex-rescue` agent |
| An argument or disagreement to settle with Codex | `peer-chat` with a Codex peer |
| gpt workers inside Workflow or Agent fan-outs | `codex-delegation:codex-workflow-fanout` skill |
| UI or runtime verification by an independent agent | `codex-delegation:codex-computer-use` skill |
| Poll, fetch or kill an official background run | `/codex:status`, `/codex:result`, `/codex:cancel` |

## Availability: probe, with a reason

Before the first adapter job of a session, probe under the cwd, sandbox and model the job will use:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-job.sh" probe --cwd <repo> --sandbox read-only
```

| `reason` | Do |
| --- | --- |
| `ok` | delegate |
| `absent` | stop: `/plugin install codex@openai-codex`, then `/codex:setup` |
| `unauthenticated` | stop: the user runs `codex login`; never copy auth files, never run login or logout yourself |
| `quota`, `unsupported` | stop and report the detail; another backend only with the user's word |
| `denied` | the sandbox or host refused the probe; that is not proof of logout, report it |
| `unknown` | report the detail; do not guess a cause |

## Model and effort

Leave `--model` and `--effort` unset: Codex runs what its own config names. Pass them only when the user or the
project asks, as the full slug the Codex CLI accepts (it resolves no family alias). The record keeps
`model_requested` beside `model_observed`; `unknown` there means Codex did not report it.

## Launch once

Pick the backend before launch. Once `start` returned, the job is collected, cancelled or reported `uncertain`: the
prompt is never sent a second time, on any backend. A different route is allowed only after a pre-launch failure the
probe or `start` established (exit 3, or a refusal before any turn began).

## Verification stance

A job's exit 0, its parsed JSON or a worker's PASS is never acceptance. Read the record: lifecycle, verdict, and every
claim's receipt (code claims `path:line` against the tested snapshot; runtime claims command, expected, observed,
exit, evidence path). Check the cited code before relaying a finding, keep confirmed and unverified apart, and read
`git status` plus the record's diff before calling a write job done. Then record the decision with `dispose`.
