# 🔁 ralphex-revmux

    /plugin install ralphex-revmux@cc-millz

Makes [revmux](https://github.com/umputun/revmux) the external reviewer of a [ralphex](https://github.com/umputun/ralphex) run and skips ralphex's own multi-lane review loops: `ralphex --tasks-only` then `ralphex --external-only`, where each external iteration is one revmux round (parallel finders → synthesis → verify, prior rounds injected).

⚠️ **Depends on** the `ralphex` and `revmux` CLIs (`brew install umputun/apps/ralphex umputun/apps/revmux`), `jq`, and — for the codex lanes — a logged-in `codex` CLI. Pairs with `revmux-kit` for the `sol-*` / `fable-*` rosters.

## Core ideas

- **One round replaces two loops** — ralphex's first review + crit/major loop + codex phase become revmux rounds through the `custom_review_script` hook; the 2-lane crit/major net after it stays as the regression check.
- **Preflight is a hard gate** — a LIVE `codex exec` turn (the only check that proves the ChatGPT token works and rotates it fresh), revmux on PATH, the profile resolving. Stale auth stops the run with the fix named; codex absent falls to `fable-*` with a warning.
- **Round kind from the diff instruction** — iteration 1 reviews the branch (`sol-panel`), later iterations review the uncommitted fixes (`sol-final`, major floor).
- **Evidence after the run** — a forensic reporter (timings, rounds, fixes by P1–P4, hiccups, hygiene) feeds a proposal-only optimizer.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `ralphex-revmux:ralphex-revmux` | 🔧 Setup + run recipe, the glue's env contract (`RALPHEX_REPOS`, `RALPHEX_BASELINE_SHA`, `RALPHEX_NO_CODEX`, profiles), the preflight verdict table |
| command | `/ralphex-revmux:run <plan>` | ▶️ Preflight → stage ① tasks → stage ② revmux-reviewed external loop → converged check → reporter + optimizer |
| agent | `ralphex-result-reporter` | 📋 Post-run report — phases + durations, review rounds, what was fixed at which priority, hiccups, git/CI hygiene (read-only) |
| agent | `ralphex-optimizer` | 🧭 3–6 numbered proposals from the report, each with its number, the file it touches and the measurement that proves it (proposes only) |
| script | `scripts/bootstrap.sh` | 📦 Installs `.ralphex/scripts/{ralphex-revmux-review,review-preflight}.sh`, `.ralphex/prompts/{custom_review,custom_eval}.txt`, appends the config snippet, ignores `.revmux/tasks` |

---

Part of [cc-millz](../../README.md).
