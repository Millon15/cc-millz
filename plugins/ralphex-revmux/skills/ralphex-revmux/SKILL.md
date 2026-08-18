---
name: ralphex-revmux
description: Wire revmux in as the external reviewer of ralphex and run the two-stage shape (`--tasks-only` then `--external-only`) that skips ralphex's own multi-lane review loops. Use when setting up ralphex + revmux in a repo, when a ralphex run needs its review preflight (codex auth, revmux, profile) checked before launch, when asked why a ralphex run took hours in review, or when another skill needs the glue script's env contract (RALPHEX_REPOS, RALPHEX_BASELINE_SHA, RALPHEX_NO_CODEX).
---
# ralphex-revmux

ralphex reviews in serial passes — a multi-lane first review, then a crit/major loop capped at `max(3, max_iterations/10)`, then codex, then the loop again — and every fixed minor buys another 25–70 min pass. revmux does one round: parallel finders → synthesis (dedupe, corroboration) → verify (confirmed/rejected/immaterial), prior rounds injected, `final`-style profiles report nothing below major. This plugin puts that round where ralphex's codex phase was, and skips ralphex Phase 2 by launching in two stages.

## Setup (once per repo)

1. `${CLAUDE_PLUGIN_ROOT}/skills/ralphex-revmux/scripts/bootstrap.sh` — copies the glue + preflight into `.ralphex/scripts/`, the two prompts into `.ralphex/prompts/`, appends the config snippet (`external_review_tool = custom`, `custom_review_script`, `max_external_iterations = 4`, `review_patience = 3`, `codex_model = gpt-5.6-sol`) to `.ralphex/config`, ignores `.revmux/tasks`. Idempotent — existing files are kept.
2. Profiles: install `revmux-kit` and run its bootstrap (`sol-panel` / `sol-final` / `fable-*`), or set `RALPHEX_REVMUX_PROFILE` / `RALPHEX_REVMUX_FINAL_PROFILE` to profiles the repo already has.
3. Fill `.revmux/profile.md` with the repo's facts — the round calibrates on it.

## Run

```bash
.ralphex/scripts/review-preflight.sh [--no-codex]        # LIVE codex turn + revmux + profile; exit 0 or STOP
ralphex --tasks-only --max-iterations 30 <plan>          # stage ①: tasks only, no review
RALPHEX_BASELINE_SHA=<sha> RALPHEX_ROOT_HEAD=<sha> ralphex --external-only --skip-finalize --max-iterations 30 <plan>   # stage ②: revmux rounds → 2-lane crit/major net (finalize skipped — it opens PRs itself)
```

`/ralphex-revmux:run <plan>` does exactly this, in the background, with a progress digest.

| Preflight exit | Meaning | Do |
| --- | --- | --- |
| 0 | everything the engine needs is live | launch |
| 1 | codex auth STALE | `codex logout && codex login` (logout FIRST), re-run — NEVER launch degraded |
| 2 | codex UNKNOWN (timeout) | retry once, then treat as STALE |
| 3 | revmux/claude absent or profile missing | fix what the detail line names |

codex not on PATH or `--no-codex` → codex SKIPPED, `sol-*` profiles fall to `fable-*` (a warn, not a stop); export `RALPHEX_NO_CODEX=1` for the launch.

## The glue's env contract (`ralphex-revmux-review.sh`)

| Var | Default | Effect |
| --- | --- | --- |
| `RALPHEX_REPOS` | `.` | space-separated repos each round reviews (`git -C <repo>`) — a polyrepo lists its sub-repos |
| `RALPHEX_BASELINE_SHA` | `origin/<default>` | root-repo base of round 1 (`base...ROOT_HEAD`) — set it when the root branch is long-lived |
| `RALPHEX_ROOT_HEAD` | `HEAD` | root-repo head pinned at launch — other sessions' commits landing mid-run stay out of the review |
| `RALPHEX_REVMUX_PROFILE` / `_FINAL_PROFILE` | `sol-panel` / `sol-final` | round 1 / re-rounds |
| `RALPHEX_NO_CODEX=1` | — | swap to the no-codex twins |
| `RALPHEX_RUBRIC_CMD` | — | `<cmd> <repo>` printing a review rubric → `context/standards-<repo>.md` |
| `RALPHEX_MIN_CONFIDENCE` | 50 | `revmux --min-confidence` |
| `RALPHEX_RUN_DIR` | `tmp/ralphex-run/<plan-slug>` | round logs + `revmux/rounds.jsonl` (one JSON line per round: profile, exit, severity counts, degraded, reported/expected) |

Round shape: iteration 1 (`{{DIFF_INSTRUCTION}}` carries `...`) = `full` → `NN-full` on the panel profile, scope = branch vs base; later iterations = `fixes` → `NN-fixes` on the final profile, scope = the uncommitted fixes (ralphex's eval prompt leaves fixes uncommitted until the last round), and `goal.md` lists every finding already raised in the task so a re-round does not re-cut the same symbol as a new major. Output to ralphex: `file:line - [severity, conf N, sources] title — body Fix: …` lines, then OPEN QUESTIONS / PRE-EXISTING blocks, or `NO ISSUES FOUND`; `REVMUX ERROR` + exit 1 when revmux exits 2 (ralphex stops instead of shipping unreviewed).

## After the run

Spawn `ralphex-result-reporter` (run_dir, progress_path, plan_path, repos, task_key, engine) then `ralphex-optimizer` (report_path, run_dir, progress_path, engine) — read-only; print both bodies verbatim.

## Guardrails

- NEVER launch when preflight is not green; codex STALE is a stop with the fix named.
- Converged = the EXTERNAL loop's own `custom review complete - no more findings` (or `external review found no issues`). A round cap (`max custom iterations reached`) followed by ralphex's clean crit/major net (`claude review complete - no more findings`) is converged-but-capped — report the cap; treat it as NOT converged only when the caller wants a strict merge gate. A `REVMUX ERROR` round or an `exit 2` last round is never reviewed.
- ralphex OVERWRITES `progress-<stem>[-codex].txt` on every relaunch — snapshot it before relaunching; and `--tasks-only` moves the plan to `docs/plans/completed/` when `move_plan_on_completion` is on, so stage ② takes the archived path.
- Root scope on a long-lived branch is `baseline..HEAD`, never the whole branch — pass `RALPHEX_BASELINE_SHA`.
