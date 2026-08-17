---
description: Run a ralphex plan in two stages — tasks only, then revmux-reviewed external loop — with a live preflight first and a report + optimizer pass at the end.
argument-hint: <plan-path> [--max-iterations=30] [--no-codex] [--repos "<r1> <r2>"] [--review-only]
---

Load the `ralphex-revmux:ralphex-revmux` skill first — it carries the env contract and the preflight table.

Parse `$ARGUMENTS`: `<plan-path>` (required unless `--review-only` and a plan is not needed), `--max-iterations` (default 30 — it also caps ralphex's crit/major loop at `max(3, N/10)`), `--no-codex`, `--repos` (default `.`), `--review-only` (skip stage ①).

1. **Setup check** — `.ralphex/scripts/ralphex-revmux-review.sh` and `.ralphex/prompts/custom_eval.txt` must exist and `.ralphex/config` must set `external_review_tool = custom`; otherwise run `${CLAUDE_PLUGIN_ROOT}/skills/ralphex-revmux/scripts/bootstrap.sh` and say what it wrote.
2. **Preflight (hard gate)** — `.ralphex/scripts/review-preflight.sh [--no-codex]`. Exit 1 → stop and tell the user `codex logout && codex login`; exit 2 → retry once after 30 s, then treat as 1; exit 3 → stop with the detail line. Exit 0 with codex `SKIPPED`/`ABSENT` → set `RALPHEX_NO_CODEX=1` for stage ②.
3. **Baseline** — `git rev-parse HEAD` → remember it as `RALPHEX_BASELINE_SHA` (the root scope of round 1); ensure the tree is clean for the repos in `--repos` (tracked files) or stop.
4. **Stage ① tasks** (skip with `--review-only`) — background: `ralphex --tasks-only --max-iterations <N> <plan>`; progress file `.ralphex/progress/progress-<plan-stem>.txt`. Wait for its `Completed:` / `Failed:` footer (poll the file with a bounded loop; never tail it into the conversation). `Failed:` → report the footer and stop.
5. **Stage ② review** — background: `RALPHEX_REPOS="<repos>" RALPHEX_BASELINE_SHA=<sha> [RALPHEX_NO_CODEX=1] ralphex --external-only --max-iterations <N> <plan>`; progress file `progress-<plan-stem>-codex.txt` (upstream names the external-only log `-codex` whatever the tool). Wait for the footer.
6. **Converged?** — the review progress file must contain `review complete - no more findings` or `external review found no issues`, and `tmp/ralphex-run/<plan-stem>/revmux/rounds.jsonl` must hold ≥1 line with `exit ∈ {0,1}`. Not converged → say so, name the last round's log, and stop; never call the run reviewed.
7. **Report** — spawn `ralphex-result-reporter` (run_dir=`tmp/ralphex-run/<plan-stem>` progress_path=both files plan_path repos task_key engine=revmux), then `ralphex-optimizer` (report_path run_dir progress_path engine=revmux). Print, in this order: your own 6-line status (plan · stages · preflight verdict · rounds + converged · wall clock · footer), the reporter body verbatim, the optimizer body verbatim.

Never open PRs, never edit code, never modify `.ralphex/**` beyond the bootstrap in step 1.
