#!/usr/bin/env bash
# sl-review-launch.sh: weekly entry point; opens an agterm session running /session-learnings:review when there is work.
#
#   sl-review-launch.sh            refresh the usage report, count open work, launch or skip; prints one outcome line
#   sl-review-launch.sh --dry-run  the same checks, then prints the agtermctl command instead of running it
#
# Outcome lines: launched <id> · skipped: nothing to review · skipped: review already open <id>
#                notified: agterm unavailable · dry-run: <command>
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE="${SESSION_LEARNINGS_HOME:-$HOME/.claude/learnings}"
REVIEW_CWD="${SESSION_LEARNINGS_REVIEW_CWD:-$HOME}"
REVIEW_PROMPT="/session-learnings:review"
WORKSPACE="session-learnings"
SESSION_NAME="session-learnings review"
DRY_RUN=0

usage() {
	echo "usage: sl-review-launch.sh [--dry-run]" >&2
	exit 64
}

main() {
	[ "${CLAUDE_LEARN_SKIP:-}" = 1 ] && exit 0
	parse_args "$@"
	refresh_report
	has_work || finish "skipped: nothing to review"
	agterm_reachable || notify_and_finish "notified: agterm unavailable" \
		"weekly review due, agterm unreachable: run $REVIEW_PROMPT"
	local open_id
	open_id="$(open_review_session)"
	[ -z "$open_id" ] || finish "skipped: review already open $open_id"
	launch_review
}

parse_args() {
	[ "$#" -eq 0 ] && return 0
	[ "$#" -eq 1 ] && [ "$1" = --dry-run ] || usage
	DRY_RUN=1
}

finish() {
	printf '%s\n' "$1"
	exit 0
}

notify_and_finish() {
	notify "$2" || echo "sl-review-launch: notification failed" >&2
	finish "$1"
}

# A failed report must not cancel the review: ready lessons still deserve the session.
refresh_report() {
	"$SCRIPTS_DIR/sl-stats.sh" report --store="$STORE" --if-stale >/dev/null ||
		echo "sl-review-launch: usage report failed, reviewing lessons only" >&2
}

has_work() {
	[ "$(count_open_proposals)" -gt 0 ] || [ "$(count_ready_candidates)" -gt 0 ]
}

count_open_proposals() {
	"$SCRIPTS_DIR/sl-stats.sh" proposals --store="$STORE" --status=open | count_lines
}

count_ready_candidates() {
	"$SCRIPTS_DIR/sl-ledger.sh" list --store="$STORE" --status=candidate |
		jq -r 'select((.flags // []) | index("ready")) | .id' | count_lines
}

count_lines() {
	sed '/^$/d' | wc -l | tr -d ' '
}

agterm_reachable() {
	command -v agtermctl >/dev/null 2>&1 && agtermctl window list --json >/dev/null 2>&1
}

# agterm-lanes renames a session once claude starts, so the open review is found by its argv, not its name.
open_review_session() {
	local window
	for window in $(open_windows); do
		agtermctl tree --json --window "$window" | jq -r --arg prompt "$REVIEW_PROMPT" '
			.result.tree.workspaces[]?.sessions[]?
			| select((.foreground // []) | index($prompt))
			| .id'
	done | sed -n '1p'
}

open_windows() {
	agtermctl window list --json | jq -r '.result.windows[] | select(.open) | .id'
}

launch_review() {
	local cmd=(agtermctl session new --cwd "$REVIEW_CWD" --workspace-name "$WORKSPACE" --create-workspace
		--name "$SESSION_NAME" --no-select --command "/bin/zsh -lc 'claude \"$REVIEW_PROMPT\"'")
	[ "$DRY_RUN" -eq 1 ] && finish "dry-run: ${cmd[*]}"
	local id
	id="$("${cmd[@]}")"
	agtermctl session status blocked --target "$id" >/dev/null ||
		echo "sl-review-launch: could not flag session $id" >&2
	notify "weekly review open in agterm workspace $WORKSPACE" || echo "sl-review-launch: notification failed" >&2
	finish "launched $id"
}

notify() {
	PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPTS_DIR/lib/sl_housekeeping.py" notify --store="$STORE" --body="$1"
}

main "$@"
