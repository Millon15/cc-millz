#!/usr/bin/env bash
#
# ralphex-revmux-review.sh (ralphex-revmux plugin) — ralphex `custom_review_script`: one
# revmux round per external-review iteration, findings converted to the
# `file:line - issue` lines ralphex hands to Claude for evaluation.
#
# Contract (ralphex): $1 = prompt file rendered from .ralphex/prompts/custom_review.txt (the
# plugin's template — bootstrap.sh installs it)
# (RALPHEX_* header lines). stdout = findings or `NO ISSUES FOUND`; stderr is
# merged into stdout by ralphex, so every diagnostic goes to the round log.
#
# Round shape:
#   iteration 1  RALPHEX_DIFF carries `...`  → kind=full,  profile $RALPHEX_REVMUX_PROFILE (sol-panel)        scope = branch vs base per repo
#   iteration N  RALPHEX_DIFF is `git diff`  → kind=fixes, profile $RALPHEX_REVMUX_FINAL_PROFILE (sol-final)  scope = uncommitted fixes per repo
#   RALPHEX_NO_CODEX=1 swaps sol-* → fable-* (or appends -claude to a custom profile)
# revmux injects every prior round of the task itself; Claude's previous rebuttals ride in context/.
#
# Env (all optional):
#   RALPHEX_REPOS                 space-separated repo paths to review (default: `.` — the repo ralphex runs in;
#                                 a polyrepo lists its sub-repos here, each reviewed with `git -C <repo>`)
#   RALPHEX_REVMUX_PROFILE        first-round profile (default sol-panel)
#   RALPHEX_REVMUX_FINAL_PROFILE  re-round profile (default sol-final)
#   RALPHEX_RUBRIC_CMD            optional command printing a repo's review rubric; run per repo as
#                                 `$RALPHEX_RUBRIC_CMD <repo>` → context/standards-<repo>.md
#   RALPHEX_BASELINE_SHA   root-repo baseline commit; root scope = baseline...ROOT_HEAD (default: origin/<default>)
#   RALPHEX_ROOT_HEAD      root-repo head pinned at launch — a long-lived root branch collects OTHER sessions'
#                          commits mid-run; pinning keeps them out of the review (default: HEAD)
#   RALPHEX_NO_CODEX=1     use the no-codex profiles
#   RALPHEX_RUN_DIR        where round logs + rounds.jsonl land (default tmp/ralphex-run/<plan-slug>)
#   RALPHEX_MIN_CONFIDENCE revmux --min-confidence (default 50)
#
# Exit: 0 always when a round ran (findings or none); 1 = revmux exit 2 / round could not be opened
# (ralphex treats a non-zero script as an executor error — the run stops instead of shipping unreviewed).
#
set -uo pipefail

PROMPT_FILE="${1:?usage: ralphex-revmux-review.sh <prompt-file>}"
MIN_CONFIDENCE="${RALPHEX_MIN_CONFIDENCE:-50}"

header() { grep -m1 "^RALPHEX_$1: " "$PROMPT_FILE" | sed "s/^RALPHEX_$1: //"; }

GOAL="$(header GOAL)"
PLAN="$(header PLAN)"
DEFAULT_BRANCH="$(header DEFAULT_BRANCH)"
DIFF_INSTRUCTION="$(header DIFF)"
PLAN_SLUG="$(basename "${PLAN:-plan}" .md)"
RUN_DIR="${RALPHEX_RUN_DIR:-tmp/ralphex-run/$PLAN_SLUG}"
LOG_DIR="$RUN_DIR/revmux"
mkdir -p "$LOG_DIR"

round_kind() {
    [[ "$DIFF_INSTRUCTION" == *"..."* ]] && echo full || echo fixes
}

no_codex_twin() { # $1=profile
    case "$1" in
        sol-*) echo "fable-${1#sol-}" ;;
        *-claude | fable-*) echo "$1" ;;
        *) echo "${1}-claude" ;;
    esac
}

profile_for() { # $1=kind
    local p="${RALPHEX_REVMUX_PROFILE:-sol-panel}"
    [[ "$1" == "fixes" ]] && p="${RALPHEX_REVMUX_FINAL_PROFILE:-sol-final}"
    [[ "${RALPHEX_NO_CODEX:-0}" == "1" ]] && p="$(no_codex_twin "$p")"
    echo "$p"
}

diverging_repos() {
    tr ' ' '\n' <<<"${RALPHEX_REPOS:-.}"
}

root_base() {
    [[ -n "${RALPHEX_BASELINE_SHA:-}" ]] && {
        echo "$RALPHEX_BASELINE_SHA"
        return
    }
    echo "origin/${DEFAULT_BRANCH:-master}"
}

repo_base() { # $1=repo
    [[ "$1" == "." ]] && {
        root_base
        return
    }
    echo "origin/${DEFAULT_BRANCH:-master}"
}

repo_head() { # $1=repo
    [[ "$1" == "." && -n "${RALPHEX_ROOT_HEAD:-}" ]] && { echo "$RALPHEX_ROOT_HEAD"; return; }
    echo HEAD
}

diff_command() { # $1=repo $2=kind
    local base
    base="$(repo_base "$1")"
    [[ "$2" == "full" ]] && echo "git -C $1 diff $base...$(repo_head "$1")" || echo "git -C $1 diff"
}

shortstat_line() { # $1=repo $2=kind
    local cmd
    cmd="$(diff_command "$1" "$2")"
    $cmd --shortstat 2>/dev/null | sed 's/^ *//'
}

next_round_name() { # $1=task_dir $2=kind
    local n=1
    [[ -d "$1" ]] && n=$(($(find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') + 1))
    printf '%02d-%s' "$n" "$2"
}

write_scope() { # $1=path $2=kind $3..=repos
    local path="$1" kind="$2"
    shift 2
    {
        echo "# Scope — ${kind} round"
        echo "- Change: $GOAL"
        echo "- Repos under review (each its own git; run every command from the workdir root):"
        local r
        for r in "$@"; do
            echo "  - \`$r\`: \`$(diff_command "$r" "$kind")\` — $(shortstat_line "$r" "$kind")"
        done
        [[ "$kind" == "fixes" ]] && echo "- Branch context (already reviewed in earlier rounds, read only to place a fix): \`git -C <repo> diff $(root_base)...HEAD\`"
        echo "- Read in full: any source or test file the diff touches"
        echo "- Ignore: \`tmp/**\`, \`.ralphex/progress/**\`, plan checkbox flips under \`docs/plans/**\`, generated agent dirs"
    } >"$path"
}

already_raised() { # every finding of the earlier rounds of this task, one line each
    local f
    for f in "$LOG_DIR"/*.json; do
        [[ -s "$f" ]] || continue
        jq -r '.findings[]? | "  - \(.file):\(.line // 0) — \(.title)"' "$f" 2>/dev/null
    done | sort -u
}

write_goal() { # $1=path $2=kind
    {
        echo "# Goal"
        echo "- $GOAL"
        echo "- Plan: \`$PLAN\` (context/plan.md carries a copy) — the tasks it lists are the intended change; report only what should not ship."
        if [[ "$2" == "fixes" ]]; then
            echo "- This round reviews the FIXES applied after the previous round. Judge whether each fix addresses its finding at the right place without regressing the neighbours."
            echo "- Already raised in this task (fixed or rebutted in earlier rounds — do NOT re-raise the same symbol below critical; a nuance of an earlier finding is a follow-up note, not a new major):"
            already_raised
        fi
        echo "- Correct only if: every introduced guard is exercised by a test; no behaviour the plan did not ask for; nothing that would fail on a second run."
        echo "- Finding nothing is a valid answer — this is a merge gate, not a quota."
    } >"$1"
}

write_standards() { # $1=context_dir $2..=repos
    [[ -n "${RALPHEX_RUBRIC_CMD:-}" ]] || return 0
    local dir="$1" r slug
    shift
    for r in "$@"; do
        slug="${r//\//-}"
        [[ "$slug" == "." ]] && slug=root
        $RALPHEX_RUBRIC_CMD "$r" >"$dir/standards-$slug.md" 2>/dev/null || command rm -f -- "$dir/standards-$slug.md"
    done
}

write_context() { # $1=context_dir $2..=repos
    mkdir -p "$1"
    [[ -f "$PLAN" ]] && cp "$PLAN" "$1/plan.md"
    write_standards "$@"
    awk '/^RALPHEX_PREVIOUS_CONTEXT_BEGIN$/{p=1;next} /^RALPHEX_PREVIOUS_CONTEXT_END$/{p=0} p' "$PROMPT_FILE" >"$1/ralphex-previous-review.md"
    [[ -s "$1/ralphex-previous-review.md" ]] || command rm -f -- "$1/ralphex-previous-review.md"
}

write_task_file() { # $1=task_file
    grep -q '^description:' "$1" 2>/dev/null && return 0
    local branch
    branch="$(git -C . branch --show-current 2>/dev/null)"
    printf -- '---\ndescription: ralphex plan %s — %s\nbranch: %s\nbase: %s\n---\n\nRounds opened by ralphex-revmux-review.sh (ralphex-revmux plugin), one per ralphex external-review iteration.\n' \
        "$PLAN_SLUG" "$GOAL" "$branch" "$(root_base)" >"$1"
}

open_round() { # $1=kind ; prints round JSON
    local task_dir round
    task_dir="$(revmux config 2>/dev/null | jq -r '.paths.tasks_dir')/$PLAN_SLUG"
    round="$(next_round_name "$task_dir" "$1")"
    revmux new --task "$PLAN_SLUG" --run "$round" 2>>"$LOG_DIR/new.log"
}

render_findings() { # $1=json path
    jq -r '
      def sev_rank: . as $s | {critical:0, major:1, minor:2} | .[$s] // 3;
      def line: "\(.file):\(.line // 0) - [\(.severity), conf \(.confidence // 0), \(.sources|join("+"))] \(.title) — \((.body // "") | gsub("\n"; " ")) Fix: \((.fix // "n/a") | gsub("\n"; " "))";
      (.findings // []) | sort_by(.severity | sev_rank) | .[] | line
    ' "$1"
}

render_extras() { # $1=json path
    jq -r '
      (if ((.open_questions // []) | length) > 0 then
         "\nOPEN QUESTIONS (decisions, not edits — answer in the PR description, do not change code for them):",
         ((.open_questions // []) | .[] | "- \(.file // "?"):\(.line // 0) \(.title // .body // .)")
       else empty end),
      (if ((.pre_existing // []) | length) > 0 then
         "\nPRE-EXISTING (not introduced by this change — fix only when cheap and safe):",
         ((.pre_existing // []) | .[] | "- \(.file // "?"):\(.line // 0) \(.title // .body // .)")
       else empty end)
    ' "$1"
}

degrade_note() { # $1=json path
    jq -r '.sources | select((.degraded // []) | length > 0) | "# revmux WARNING: partial review — degraded sources: \(.degraded|join(", ")) (\(.reported)/\(.expected) reported)"' "$1"
}

journal_round() { # $1=round $2=profile $3=exit $4=json
    local counts
    counts="$(jq -c '{critical: ([.findings[]?|select(.severity=="critical")]|length), major: ([.findings[]?|select(.severity=="major")]|length), minor: ([.findings[]?|select(.severity=="minor")]|length), open_questions: ((.open_questions//[])|length), pre_existing: ((.pre_existing//[])|length), immaterial: ((.immaterial//[])|length), degraded: (.sources.degraded//[]), reported: (.sources.reported//null), expected: (.sources.expected//null), duration_ms: (.stats.duration_ms//null)}' "$4" 2>/dev/null || echo '{}')"
    printf '{"round":"%s","profile":"%s","exit":%s,"counts":%s,"json":"%s"}\n' "$1" "$2" "$3" "$counts" "$4" >>"$LOG_DIR/rounds.jsonl"
}

run_round() { # $1=round $2=profile ; prints json path, returns revmux exit
    local json="$LOG_DIR/$1.json" log="$LOG_DIR/$1.log"
    revmux --task "$PLAN_SLUG" --run "$1" --profile "$2" --no-tui --min-confidence "$MIN_CONFIDENCE" >"$json" 2>"$log"
    local rc=$?
    echo "$json"
    return $rc
}

main() {
    local kind profile round_json round scope goal ctx task_file r
    kind="$(round_kind)"
    profile="$(profile_for "$kind")"
    local repos=()
    while IFS= read -r r; do [[ -n "$r" ]] && repos+=("$r"); done < <(diverging_repos)
    [[ ${#repos[@]} -gt 0 ]] || {
        echo "NO ISSUES FOUND"
        echo "# revmux: no diverging repo to review" >&2
        return 0
    }

    round_json="$(open_round "$kind")" || {
        echo "REVMUX ERROR: could not open a round (see $LOG_DIR/new.log)"
        return 1
    }
    round="$(basename "$(jq -r '.round_dir' <<<"$round_json")")"
    scope="$(jq -r '.scope' <<<"$round_json")"
    goal="$(jq -r '.goal' <<<"$round_json")"
    ctx="$(jq -r '.context' <<<"$round_json")"
    task_file="$(jq -r '.task_file' <<<"$round_json")"

    write_scope "$scope" "$kind" "${repos[@]}"
    write_goal "$goal" "$kind"
    write_context "$ctx" "${repos[@]}"
    write_task_file "$task_file"

    local json rc
    json="$(run_round "$round" "$profile")"
    rc=$?
    journal_round "$round" "$profile" "$rc" "$json"

    case "$rc" in
        0)
            degrade_note "$json"
            echo "NO ISSUES FOUND"
            render_extras "$json"
            ;;
        1)
            echo "# revmux round $round ($profile): findings below are verified by revmux; open questions/pre-existing follow"
            degrade_note "$json"
            render_findings "$json"
            render_extras "$json"
            ;;
        *)
            echo "REVMUX ERROR: round $round exited $rc — $(tail -n 3 "$LOG_DIR/$round.log" | tr '\n' ' ')"
            return 1
            ;;
    esac
    return 0
}

main
