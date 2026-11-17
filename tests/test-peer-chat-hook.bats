#!/usr/bin/env bats
#
# tests/test-peer-chat-hook.bats
#
# session-start-peer.sh is the SessionStart hook both peer plugins ship. It prints the peer-mode
# directive only for the lane the marker names, only in a top-level session, and exits 0 on every
# input. Nested sessions are real process chains: a symlink to bash named `claude` or `codex`
# shows under that name in `ps` comm on macOS (argv[0]) and Linux (the exec'd file name), so the
# suite fakes an agent parent without a test seam in the script. Each `-c` string ends in `:` so
# bash does not exec its last command in place and drop the fake parent. The runner's own
# ancestors (a claude, a codex exec) would add to the count, so a `ps` stub hides every process
# from the test shell upward and the suite reads the same at any depth.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	HOOK="${REPO_ROOT}/shared/peer-chat/session-start-peer.sh"
	export CLAUDE_CONFIG_DIR="${TMP}/config"
	mkdir -p "${CLAUDE_CONFIG_DIR}"
	unset PEER_CHAT_MODE PEER_CHAT_NAME CLAUDE_CODE_ENTRYPOINT PEER_CHAT_CLAUDE_COMMAND PEER_CHAT_CODEX_COMMAND
	export AGTERM_ENABLED=1
	hide_runner_ancestors
}

# hide_runner_ancestors: a `ps` stub on PATH that drops the test shell and every process above it.
hide_runner_ancestors() {
	local real_ps ambient
	real_ps=$(command -v ps)
	# bash 3.2 has no BASHPID: sh walks up from its parent, the live subshell under the test shell.
	# shellcheck disable=SC2016
	ambient=$(sh -c 'pid=$PPID; while [ "${pid:-0}" -gt 1 ]; do printf " %s" "$pid"; pid=$(ps -o ppid= -p "$pid" | tr -d " "); done')
	printf '#!/bin/bash\n"%s" "$@" | awk -v ambient="%s" %s\n' "$real_ps" "$ambient" \
		"'BEGIN { split(ambient, list, \" \"); for (i in list) hide[list[i]] = 1 } !(\$1 in hide)'" \
		>"${STUB_BIN}/ps"
	chmod +x "${STUB_BIN}/ps"
}

teardown() { teardown_tmp; }

mode() { printf '%s\n' "$1" >"${CLAUDE_CONFIG_DIR}/peer-chat.mode"; }

hook() { /bin/bash "$HOOK" "$1" <<<'{"hook_event_name":"SessionStart","source":"startup"}'; }

# under <argv0>... <lane>: runs the hook below one fake agent process per argv0, outermost first.
under() {
	local lane=${*: -1} argv0
	local command="/bin/bash '$HOOK' $lane </dev/null; :"
	local -a chain=("${@:1:$#-1}")
	mkdir -p "${TMP}/agents"
	for ((i = ${#chain[@]} - 1; i >= 0; i--)); do
		argv0=${chain[i]}
		ln -sf /bin/bash "${TMP}/agents/${argv0}"
		command="'${TMP}/agents/${argv0}' -c \"${command//\"/\\\"}\"; :"
	done
	/bin/bash -c "$command"
}

directive() { jq -r '.hookSpecificOutput.additionalContext' <<<"$output"; }

@test "agterm lane prints the directive naming the agterm skills" {
	mode agterm
	run hook agterm
	[ "$status" -eq 0 ]
	jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$output"
	[[ "$(directive)" == *"peer-chat:build"* ]] || false
	[[ "$(directive)" != *"peer-chat-bg"* ]] || false
}

@test "bg lane prints the directive naming the peer-chat-bg skills, agterm or not" {
	mode bg
	unset AGTERM_ENABLED
	run hook bg
	[ "$status" -eq 0 ]
	[[ "$(directive)" == *"peer-chat-bg:peer-chat"* ]] || false
	[[ "$(directive)" == *"peer-chat-bg:build"* ]] || false
}

@test "agterm lane is silent outside agterm" {
	mode agterm
	unset AGTERM_ENABLED
	run hook agterm
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "each lane is silent when the marker names the other lane" {
	mode agterm
	run hook bg
	[ -z "$output" ]
	mode bg
	run hook agterm
	[ -z "$output" ]
}

@test "marker 0, a missing marker and an unknown value are silent" {
	run hook agterm
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	mode 0
	run hook agterm
	[ -z "$output" ]
	mode yes
	run hook agterm
	[ -z "$output" ]
}

@test "a marker without a trailing newline still counts" {
	printf 'agterm' >"${CLAUDE_CONFIG_DIR}/peer-chat.mode"
	run hook agterm
	[[ "$(directive)" == *"Peer mode is ON"* ]] || false
}

@test "PEER_CHAT_MODE overrides the marker in both directions" {
	mode 0
	PEER_CHAT_MODE=agterm run hook agterm
	[[ "$(directive)" == *"Peer mode is ON"* ]] || false
	mode agterm
	PEER_CHAT_MODE=0 run hook agterm
	[ -z "$output" ]
}

@test "the spawned peer stays silent" {
	mode agterm
	PEER_CHAT_NAME=codex run hook agterm
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "an SDK entrypoint stays silent" {
	mode agterm
	CLAUDE_CODE_ENTRYPOINT=sdk-cli run hook agterm
	[ -z "$output" ]
	CLAUDE_CODE_ENTRYPOINT=cli run hook agterm
	[[ "$(directive)" == *"Peer mode is ON"* ]] || false
}

@test "codex nested under claude stays silent" {
	mode agterm
	run under claude codex agterm
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "claude nested under codex stays silent" {
	mode agterm
	run under codex claude agterm
	[ -z "$output" ]
}

@test "wrappers count as agents only once PEER_CHAT_*_COMMAND names them" {
	mode agterm
	run under my-claude my-codex agterm
	[[ "$(directive)" == *"Peer mode is ON"* ]] || false
	PEER_CHAT_CLAUDE_COMMAND=my-claude PEER_CHAT_CODEX_COMMAND=/opt/bin/my-codex run under my-claude my-codex agterm
	[ -z "$output" ]
}

@test "malformed or empty stdin and a missing lane still exit 0" {
	mode agterm
	run /bin/bash "$HOOK" agterm <<<'not json'
	[ "$status" -eq 0 ]
	run /bin/bash "$HOOK" agterm </dev/null
	[ "$status" -eq 0 ]
	run /bin/bash "$HOOK" </dev/null
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "both plugins ship the shared script and run it with their own lane" {
	for plugin in peer-chat peer-chat-bg; do
		cmp "$HOOK" "${REPO_ROOT}/plugins/${plugin}/scripts/session-start-peer.sh"
	done
	jq -e '.hooks.SessionStart[0].hooks[0].command | endswith("session-start-peer.sh\" agterm")' \
		"${REPO_ROOT}/plugins/peer-chat/hooks/hooks.json"
	jq -e '.hooks.SessionStart[0].hooks[0].command | endswith("session-start-peer.sh\" bg")' \
		"${REPO_ROOT}/plugins/peer-chat-bg/hooks/hooks.json"
}
