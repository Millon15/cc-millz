#!/usr/bin/env bats
#
# tests/test-session-learnings-hook.bats: the SessionEnd hook queues one job per session,
# atomically, and exits 0 on every input; the install script's --explain contract.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	HOOK="${REPO_ROOT}/plugins/session-learnings/scripts/sl-hook.sh"
	INSTALL="${REPO_ROOT}/plugins/session-learnings/scripts/sl-install.sh"
	export SESSION_LEARNINGS_HOME="$TMP/store"
	unset CLAUDE_LEARN_SKIP CLAUDE_PLUGIN_ROOT
}

teardown() { teardown_tmp; }

end_event() {
	jq -nc --arg sid "$1" '{session_id: $sid, transcript_path: "/x/projects/-p/\($sid).jsonl", cwd: "/p", reason: "prompt_input_exit", hook_event_name: "SessionEnd"}'
}

queued() {
	find "$SESSION_LEARNINGS_HOME/queue" -type f 2>/dev/null | wc -l | tr -d ' '
}

@test "writes exactly one queue file carrying the job fields" {
	run "$HOOK" <<<"$(end_event abc-123)"
	[ "$status" -eq 0 ]
	[ "$(queued)" -eq 1 ]
	jq -e '.session_id == "abc-123" and .reason == "prompt_input_exit" and .source == "hook" and .attempts == 0' \
		"$SESSION_LEARNINGS_HOME/queue/abc-123.json"
}

@test "a re-delivered SessionEnd overwrites the same job instead of adding one" {
	"$HOOK" <<<"$(end_event abc-123)"
	"$HOOK" <<<"$(end_event abc-123)"
	[ "$(queued)" -eq 1 ]
}

@test "CLAUDE_LEARN_SKIP=1 queues nothing" {
	CLAUDE_LEARN_SKIP=1 run "$HOOK" <<<"$(end_event abc-123)"
	[ "$status" -eq 0 ]
	[ "$(queued)" -eq 0 ]
}

@test "a path-traversing session id is ignored and the hook still exits 0" {
	run "$HOOK" <<<"$(end_event '../../etc/x')"
	[ "$status" -eq 0 ]
	[ "$(queued)" -eq 0 ]
}

@test "malformed stdin exits 0 and writes nothing" {
	run "$HOOK" <<<'not json'
	[ "$status" -eq 0 ]
	run "$HOOK" <<<'{"session_id": 5}'
	[ "$status" -eq 0 ]
	[ "$(queued)" -eq 0 ]
}

@test "the plugin root is remembered for the launchd shim" {
	CLAUDE_PLUGIN_ROOT=/cache/session-learnings/0.1.0 "$HOOK" <<<"$(end_event abc-123)"
	[ "$(cat "$SESSION_LEARNINGS_HOME/plugin-root")" = /cache/session-learnings/0.1.0 ]
}

@test "the hook finishes well inside the 1.5 s SessionEnd budget" {
	local started elapsed_ms
	started="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
	"$HOOK" <<<"$(end_event abc-123)"
	elapsed_ms=$(($(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - started))
	[ "$elapsed_ms" -lt 500 ]
}

@test "install --explain mirrors every value in sources and has no side effects" {
	run "$INSTALL" --explain
	[ "$status" -eq 0 ]
	assert_explain_complete "$output"
	assert_explain_source "$output" store detected:SESSION_LEARNINGS_HOME
	assert_explain_source "$output" model default
	assert_explain_source "$output" plugin_root detected:script-location
	[ ! -e "$SESSION_LEARNINGS_HOME" ]
}

@test "install renders a lint-clean plist and a shim that follows plugin-root" {
	stub launchctl 'exit 0'
	SESSION_LEARNINGS_LAUNCH_AGENTS="$TMP/agents" run "$INSTALL"
	[ "$status" -eq 0 ]
	plutil -lint "$TMP/agents/io.github.millon15.session-learnings.plist"
	grep -q "$SESSION_LEARNINGS_HOME/queue" "$TMP/agents/io.github.millon15.session-learnings.plist"
	[ -x "$SESSION_LEARNINGS_HOME/bin/sl-run" ]
	[ -f "$SESSION_LEARNINGS_HOME/.since" ]
	[ "$(cat "$SESSION_LEARNINGS_HOME/plugin-root")" = "${REPO_ROOT}/plugins/session-learnings" ]
}

@test "install writes worker overrides into the plist, launchd does not inherit the installer's env" {
	stub launchctl 'exit 0'
	SESSION_LEARNINGS_MODEL=override-model SESSION_LEARNINGS_DIGEST_BUDGET=2000 SESSION_LEARNINGS_LAUNCH_AGENTS="$TMP/agents" "$INSTALL"
	local plist="$TMP/agents/io.github.millon15.session-learnings.plist"
	[ "$(plutil -extract EnvironmentVariables.SESSION_LEARNINGS_MODEL raw "$plist")" = override-model ]
	[ "$(plutil -extract EnvironmentVariables.SESSION_LEARNINGS_DIGEST_BUDGET raw "$plist")" = 2000 ]
}

@test "install keeps a store path with &, quotes and XML characters intact" {
	stub launchctl 'exit 0'
	export SESSION_LEARNINGS_HOME="$TMP/store&notes <\"x\">"
	SESSION_LEARNINGS_LAUNCH_AGENTS="$TMP/agents" run "$INSTALL"
	[ "$status" -eq 0 ]
	local plist="$TMP/agents/io.github.millon15.session-learnings.plist"
	[ "$(plutil -extract EnvironmentVariables.SESSION_LEARNINGS_HOME raw "$plist")" = "$SESSION_LEARNINGS_HOME" ]
	[ "$(plutil -extract QueueDirectories.0 raw "$plist")" = "$SESSION_LEARNINGS_HOME/queue" ]
	[ "$(plutil -extract ProgramArguments.1 raw "$plist")" = "$SESSION_LEARNINGS_HOME/bin/sl-run" ]
}
