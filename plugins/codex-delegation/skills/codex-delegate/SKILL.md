---
name: codex-delegate
description: Routing brain for delegating work to Codex CLI. Use when the user asks Codex/GPT to review, implement, diagnose, or verify something, when a second independent perspective is wanted, or when the model rubric calls for a cheap second-tier worker. Routes through the openai-codex plugin — never hand-rolled codex prompts.
---
# Codex Delegate

Second-tier workforce = Codex CLI. Claude (Fable/Opus) = orchestrator + taste owner. Codex = bulk, second opinions, independent verification.

## Law: plugin wins

openai-codex plugin implementations ALWAYS win over hand-written `codex exec`/`codex review` shell prompts. Hand-rolled shapes ONLY where plugin has no lane (workflow fan-out → `codex-workflow-fanout` skill; UI/runtime verification → `codex-computer-use` skill).

## Preflight (once per session)

1. Glob `~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs` — missing → STOP, tell user: `/plugin install codex@openai-codex` then `/codex:setup`.
2. Auth doubt (first call after long idle, 401 risk) → `/codex:status` first.

## Routing

| Intent | Route |
| --- | --- |
| Review local changes / branch / commit | `/codex:review` (native reviewer, fg/bg) |
| Review with custom focus or adversarial stance | `/codex:adversarial-review` |
| Implementation, bugfix, diagnosis, research handoff | `codex:codex-rescue` agent (`--write` default; `--background` for long runs; `--resume` continue thread) |
| Poll / fetch / kill background runs | `/codex:status`, `/codex:result`, `/codex:cancel` |
| Fan-out gpt workers inside Workflow/Agent | `codex-workflow-fanout` skill |
| Verify UI/runtime behavior (screenshots, app launch) | `codex-computer-use` skill |
| Prompt composition for any above | reuse plugin `gpt-5-4-prompting` skill (XML block contracts) |

## Model rubric

Rankings 1–10, higher = better. Cost = what user pays (OpenAI near-free for them), not list price.

| model | cost | intelligence | taste | use for |
| --- | --- | --- | --- | --- |
| `sol` | 9 | 9 | 6 | MAIN Codex model, the `fable` analogue: reviews, hard diagnosis, substantial impl; bulk/mechanical work at a lower effort |
| `fable` | 2 | 9 | 9 | orchestration, taste-critical, final judgment |
| `opus` | 4 | 7 | 8 | Claude subagent tier |

- Codex has no family alias and the companion maps only `spark`, so `--model` takes a full slug. Today's `sol` is `gpt-6.1-sol`: pass `--model gpt-6.1-sol`. Omitting `--model` runs whatever `~/.codex/config.toml` sets.
- Bulk/mechanical work (clear-spec impl, data analysis, migrations) runs on `sol` too, with `--effort low`: the separate bulk model retires on 2026-10-14.
- Effort: `--effort none|minimal|low|medium|high|xhigh` — leave unset default; raise only for hardest diagnosis.
- Defaults, not limits: cheap output below bar → rerun with smarter model, no asking. Intelligence > taste > cost for anything that ships.
- User-facing output (UI, copy, API design) needs taste ≥ 7 → Claude models, not Codex.

## Verification stance

Codex output = evidence, not authority. Before relaying findings: inspect cited code enough to judge real vs speculative; separate confirmed from unverified in response. Codex made edits → inspect `git status` + `git diff` before declaring done.