#!/usr/bin/env bash
# sl-hook.sh: SessionEnd hook; queues the ended session for the worker and exits 0, never blocking the exit.
#
# Claude Code gives SessionEnd hooks 1.5 s in total, so no LLM work happens here:
# one jq call, one atomic write of queue/<session_id>.json (a re-delivery overwrites it).
# The temp file lives outside queue/: launchd QueueDirectories re-fires while queue/ holds anything.
set -uo pipefail

STORE="${SESSION_LEARNINGS_HOME:-$HOME/.claude/learnings}"

main() {
	[ "${CLAUDE_LEARN_SKIP:-}" = 1 ] && return 0
	local job session_id
	job="$(build_job)" || return 0
	session_id="$(jq -r '.session_id' <<<"$job")"
	is_safe_session_id "$session_id" || return 0
	mkdir -p "$STORE/queue" "$STORE/tmp" || return 0
	remember_plugin_root
	write_atomically "$STORE/queue/$session_id.json" "$job"
}

build_job() {
	jq -ce --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
		select((.session_id | type) == "string" and (.transcript_path | type) == "string")
		| {session_id, transcript_path, cwd, reason, ts: $ts, source: "hook", attempts: 0}'
}

is_safe_session_id() {
	[[ "$1" =~ ^[A-Za-z0-9_-]{1,128}$ ]]
}

# The launchd shim reads this file, so a plugin update moves the worker with it.
remember_plugin_root() {
	[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 0
	write_atomically "$STORE/plugin-root" "$CLAUDE_PLUGIN_ROOT"
}

write_atomically() {
	local target="$1" body="$2" tmp
	tmp="$(mktemp "$STORE/tmp/hook.XXXXXX")" || return 0
	printf '%s\n' "$body" >"$tmp" && mv -f "$tmp" "$target"
}

main
exit 0
