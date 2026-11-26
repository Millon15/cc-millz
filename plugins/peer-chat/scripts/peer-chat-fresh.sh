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
	pane_id='' explicit_pane=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--focus) focus="${2:-}" && shift 2 ;;
		--resume) resume="${2:-}" && shift 2 ;;
		--session) session="${2:-}" && shift 2 ;;
		--pane) pane="${2:-}" && explicit_pane=1 && shift 2 ;;
		--pane-id) pane_id="${2:-}" && shift 2 ;;
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

ctl() {
	if [ -n "${AGTERM_SOCKET:-}" ]; then
		agtermctl "$@" --socket "$AGTERM_SOCKET"
	else
		agtermctl "$@"
	fi
}

bind_pane() {
	[ -z "$pane_id" ] || return 0
	local snapshot token='' window
	if [ "$session" = "${AGTERM_SESSION_ID:-}" ]; then
		[ "$explicit_pane" -eq 1 ] || token="${AGTERM_PANE_ID:-}"
		window="${AGTERM_WINDOW_ID:-}"
	fi
	if [ -n "${window:-}" ]; then
		snapshot="$(ctl tree --json --window "$window")" || return 1
	else
		snapshot="$(ctl tree --json)" || return 1
	fi
	pane_id="$(jq -er --arg session "$session" --arg pane "$pane" --arg token "$token" '
		[.. | objects | select(.surfaces? and (.id | ascii_downcase | startswith($session | ascii_downcase)))
		 | .surfaces[] | select(if $token == "" then .kind == $pane else .paneID == $token end)
		 | .paneID | strings | select(length > 0)] | select(length == 1) | .[0]
	' <<<"$snapshot")" || die "could not resolve one live pane id for $session" 1
}

log() { printf '%s %s\n' "$(date +%T)" "$1" >>"$LOG"; }
screen() { ctl session text --target "$session" --pane-id "$pane_id" --lines 14; }
boundaries() { grep -c '"subtype":"compact_boundary"' "$transcript" 2>/dev/null || true; }
busy() { grep -Eq "$BUSY_RE" <<<"$1"; }
composer_empty() { grep -Eq "$EMPTY_COMPOSER_RE" <<<"$1"; }
expired() { [ "$(date +%s)" -ge "$deadline" ]; }

watch_error() {
	log "$1"
	printf 'peer-chat-fresh: %s\n' "$1" >&2
	return 1
}

read_screen() {
	local current
	if current="$(screen 2>&1)"; then
		printf '%s\n' "$current"
	else
		watch_error "could not read pane $1: $current"
	fi
}

# wait_until_idle: IDLE_POLLS consecutive polls with no spinner and an empty composer.
wait_until_idle() {
	local idle=0 current=''
	while ! expired; do
		current="$(read_screen "$1")" || return 1
		if busy "$current" || ! composer_empty "$current"; then idle=0; else idle=$((idle + 1)); fi
		[ "$idle" -ge "$IDLE_POLLS" ] && return 0
		sleep "$POLL"
	done
	printf '%s\n' "$current" >>"$LOG"
	watch_error "timeout waiting for an idle composer $1"
}

wait_for_compaction() {
	while ! expired; do
		[ "$(boundaries)" -gt "$1" ] && return 0
		sleep "$POLL"
	done
	return 1
}

type_line() {
	local error
	if ! error="$(ctl session type --target "$session" --pane-id "$pane_id" "$2" 2>&1 >/dev/null)"; then
		watch_error "could not $1: $error"
	fi
}

# submit: type the text, then Return on its own, then one more Return if the text is still in the composer.
submit() {
	local current
	type_line "type $1" "$2" || return 1
	sleep 1
	type_line "submit $1" $'\n' || return 1
	sleep 5
	current="$(read_screen "after submitting $1")" || return 1
	busy "$current" || composer_empty "$current" && return 0
	log "composer still holds the line; one more Return"
	type_line "retry Return for $1" $'\n'
}

watch() {
	local base
	deadline=$(($(date +%s) + TIMEOUT))
	base="$(boundaries)"
	log "armed session=$session pane-id=$pane_id baseline=$base transcript=$transcript"
	sleep 5
	wait_until_idle "before /compact" || return 1
	submit /compact "/compact $focus" || return 1
	log "typed /compact"
	wait_for_compaction "$base" || { watch_error "timeout: no new compact_boundary"; return 1; }
	log "compact_boundary written"
	wait_until_idle "after compaction" || return 1
	submit "the resume line" "$resume" || return 1
	log "typed resume line"
}

arm() {
	nohup "$0" --foreground --focus "$focus" --resume "$resume" --session "$session" --pane-id "$pane_id" \
		--claude-session "$claude_session" >/dev/null 2>&1 &
	jq -cn --arg log "$LOG" --argjson pid "$!" '{state: "armed", log: $log, pid: $pid}'
}

main() {
	parse_args "$@"
	require_host
	bind_pane || return 1
	LOG="${TMPDIR:-/tmp}/peer-chat-fresh.$claude_session.log"
	if [ "$foreground" -eq 1 ]; then
		watch
	else
		arm
	fi
}

main "$@"
