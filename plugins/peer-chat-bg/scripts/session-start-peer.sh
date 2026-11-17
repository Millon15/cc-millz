#!/bin/bash
#
# session-start-peer.sh <agterm|bg> - peer-chat SessionStart hook: tells a top-level
# session that peer mode is on, so the user never types a peer-chat command.
#
# stdin:  SessionStart payload (JSON), drained and ignored.
# stdout: { "hookSpecificOutput": { "hookEventName": "SessionStart", "additionalContext": "<directive>" } }
#         when this lane is on, nothing otherwise. Text only: the skill opens a peer on its first send.
# opt-in: first line of ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/peer-chat.mode, `0`, `agterm` or `bg`;
#         PEER_CHAT_MODE overrides it per run. A settings.json `env` block never reaches a hook.
# silent: PEER_CHAT_NAME set (the spawned peer), CLAUDE_CODE_ENTRYPOINT=sdk*, the agterm lane
#         outside agterm, or two agent processes among the ancestors: a nested headless run
#         inherits every env signal, and Codex's payload names no exec mode. Agent names are
#         `claude`, `codex` and the basenames of PEER_CHAT_CLAUDE_COMMAND / PEER_CHAT_CODEX_COMMAND;
#         a name the guard misses undercounts, so a nested run gets the text, never a pane.
# exit:   0 always. A hook must never block session start.
# deps:   jq, ps, awk
#
# Portability: `read -r -d ''` instead of `$(cat <<'EOF' … )`, because bash 3.2 (macOS)
# mis-parses an apostrophe inside a heredoc nested in $( ).
#
set -uo pipefail

main() {
	local lane=${1:-}
	cat >/dev/null 2>&1 || true
	lane_is_on "$lane" || return 0
	session_is_top_level || return 0
	print_directive "$lane"
}

lane_is_on() {
	[ "$(configured_mode)" = "$1" ] || return 1
	case "$1" in
	bg) return 0 ;;
	agterm) [ "${AGTERM_ENABLED:-}" = 1 ] ;;
	*) return 1 ;;
	esac
}

configured_mode() {
	local mode=${PEER_CHAT_MODE:-}
	local file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/peer-chat.mode"
	if [ -z "$mode" ] && [ -r "$file" ]; then
		IFS= read -r mode <"$file" || true
	fi
	printf '%s' "$mode"
}

session_is_top_level() {
	[ -z "${PEER_CHAT_NAME:-}" ] || return 1
	case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) return 1 ;; esac
	[ "$(agent_ancestor_count)" -lt 2 ]
}

agent_names() {
	local claude=${PEER_CHAT_CLAUDE_COMMAND:-claude} codex=${PEER_CHAT_CODEX_COMMAND:-codex}
	printf 'claude codex %s %s' "${claude##*/}" "${codex##*/}"
}

# `comm` as the last column is unabridged: argv[0] on macOS, the exec'd file name on Linux.
agent_ancestor_count() {
	ps -axo pid=,ppid=,comm= 2>/dev/null | awk -v pid="$PPID" -v names="$(agent_names)" '
		BEGIN { split(names, list, " "); for (i in list) agent[list[i]] = 1 }
		{ id = $1; parent[id] = $2; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, ""); name[id] = $0 }
		END {
			for (hops = 0; pid > 1 && hops < 64; hops++) {
				base = name[pid]; sub(/.*\//, "", base); sub(/^-/, "", base)
				if (base in agent) count++
				pid = parent[pid]
			}
			print count + 0
		}'
}

print_directive() {
	local chat=peer-chat:peer-chat build=peer-chat:build where="the peer opens in the other agterm pane"
	if [ "$1" = bg ]; then
		chat=peer-chat-bg:peer-chat build=peer-chat-bg:build where="a native background peer starts"
	fi
	local text
	IFS= read -r -d '' text <<EOF || true
Peer mode is ON for this session (lane: $1, set in peer-chat.mode). The user does not type
/$chat or /$build here; picking the tier for each task is yours:

1. A lookup, a typo, a one-line change: work solo, no peer.
2. A decision with two defensible options, a root cause nobody has tried to disprove, a diff
   about to ship with no reviewer: load the $chat skill, then bring the peer in
   ($where on the first send).
3. Implementing an agreed design that spans several files: load the $build skill.

A prompt that opens with "Chat from " is the peer talking: load $chat and answer through its
transport. Name the tier in one line when you bring the peer in.
EOF
	command -v jq >/dev/null 2>&1 || return 0
	jq -nc --arg text "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $text}}'
}

main "$@"
exit 0
