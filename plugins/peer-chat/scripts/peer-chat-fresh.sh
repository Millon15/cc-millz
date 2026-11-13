#!/usr/bin/env bash
# peer-chat-fresh — compact this Claude Code session after its turn ends, then resume it with one typed line.
#
#   peer-chat-fresh.sh --focus <text> --resume <line> [--session ID] [--pane left|right] [--claude-session ID]
#
# Arms a detached watcher and returns at once with one JSON line. After the caller's turn ends the watcher
# types `/compact <focus>`, waits for a new compact_boundary in the session transcript and an idle pane,
# then types <line>. Each line is typed first and submitted by a SEPARATE Return keystroke: a long line
# typed together with its newline reads as a paste, and the newline stays in the composer as text.
#
# Exit codes: 0 armed · 2 usage · 3 not available here (no agterm, no Claude Code session id, no transcript):
# print `/compact <focus>` and <line> for the user instead.
set -u

POLL=2
IDLE_POLLS=3
TIMEOUT="${PEER_CHAT_FRESH_TIMEOUT:-1800}"
BUSY_RE='… \([0-9]+[smh]'
PAD="[ "$'\xc2\xa0'"]*"
EMPTY_COMPOSER_RE="^❯${PAD}(\[⧉[^]]*\]${PAD})?\$"

die() {
	printf 'peer-chat-fresh: %s\n' "$1" >&2
	exit "$2"
}

parse_args() {
	focus='' resume='' foreground=0
	session="${AGTERM_SESSION_ID:-}" pane="${AGTERM_PANE:-left}" claude_session="${CLAUDE_CODE_SESSION_ID:-}"
	while [ $# -gt 0 ]; do
		case "$1" in
		--focus) focus="${2:-}" && shift 2 ;;
		--resume) resume="${2:-}" && shift 2 ;;
		--session) session="${2:-}" && shift 2 ;;
		--pane) pane="${2:-}" && shift 2 ;;
		--claude-session) claude_session="${2:-}" && shift 2 ;;
		--foreground) foreground=1 && shift ;;
		*) die "unknown argument: $1" 2 ;;
		esac
	done
	[ -n "$focus" ] && [ -n "$resume" ] || die "usage: peer-chat-fresh.sh --focus <text> --resume <line>" 2
}

find_transcript() {
	local candidate
	for candidate in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$claude_session".jsonl; do
		[ -f "$candidate" ] && printf '%s' "$candidate" && return 0
	done
	return 1
}

require_host() {
	command -v agtermctl >/dev/null 2>&1 || die "agtermctl not on PATH; print both lines for the user" 3
	[ -n "$session" ] || die "no agterm session id; print both lines for the user" 3
	[ -n "$claude_session" ] || die "no CLAUDE_CODE_SESSION_ID; print both lines for the user" 3
	transcript="$(find_transcript)" || die "no transcript for session $claude_session; print both lines for the user" 3
}

log() { printf '%s %s\n' "$(date +%T)" "$1" >>"$LOG"; }
screen() { agtermctl session text --target "$session" --pane "$pane" --lines 14 2>/dev/null; }
boundaries() { grep -c '"subtype":"compact_boundary"' "$transcript" 2>/dev/null || true; }
busy() { screen | grep -Eq "$BUSY_RE"; }
composer_empty() { screen | grep -Eq "$EMPTY_COMPOSER_RE"; }
expired() { [ "$(date +%s)" -ge "$deadline" ]; }

# wait_until_idle: IDLE_POLLS consecutive polls with no spinner and an empty composer.
wait_until_idle() {
	local idle=0
	while ! expired; do
		if busy || ! composer_empty; then idle=0; else idle=$((idle + 1)); fi
		[ "$idle" -ge "$IDLE_POLLS" ] && return 0
		sleep "$POLL"
	done
	return 1
}

wait_for_compaction() {
	while ! expired; do
		[ "$(boundaries)" -gt "$1" ] && return 0
		sleep "$POLL"
	done
	return 1
}

# submit: type the text, then Return on its own, then one more Return if the text is still in the composer.
submit() {
	agtermctl session type --target "$session" --pane "$pane" "$1" >/dev/null
	sleep 1
	agtermctl session type --target "$session" --pane "$pane" $'\n' >/dev/null
	sleep 5
	busy || composer_empty && return 0
	log "composer still holds the line; one more Return"
	agtermctl session type --target "$session" --pane "$pane" $'\n' >/dev/null
}

give_up() {
	log "timeout: $1"
	screen >>"$LOG"
	exit 1
}

watch() {
	local base
	deadline=$(($(date +%s) + TIMEOUT))
	base="$(boundaries)"
	log "armed session=$session pane=$pane baseline=$base transcript=$transcript"
	sleep 5
	wait_until_idle || give_up "the turn never ended"
	submit "/compact $focus"
	log "typed /compact"
	wait_for_compaction "$base" || give_up "no new compact_boundary"
	log "compact_boundary written"
	wait_until_idle || give_up "pane never went idle after compaction"
	submit "$resume"
	log "typed resume line"
}

arm() {
	nohup "$0" --foreground --focus "$focus" --resume "$resume" --session "$session" --pane "$pane" \
		--claude-session "$claude_session" >/dev/null 2>&1 &
	jq -cn --arg log "$LOG" --argjson pid "$!" '{state: "armed", log: $log, pid: $pid}'
}

main() {
	parse_args "$@"
	require_host
	LOG="${TMPDIR:-/tmp}/peer-chat-fresh.$claude_session.log"
	[ "$foreground" -eq 1 ] && watch && return 0
	arm
}

main "$@"
