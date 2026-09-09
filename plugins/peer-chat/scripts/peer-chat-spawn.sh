#!/usr/bin/env bash
# peer-chat-spawn — make sure Codex is running in the RIGHT pane of this agterm session.
#
#   peer-chat-spawn.sh            # open the split if needed, start codex, wait until it runs
#   peer-chat-spawn.sh --restart  # quit the codex already there, then start a fresh one
#   peer-chat-spawn.sh --explain  # print the resolved config as JSON, change nothing
#
# peer-chat.py hard-codes the layout: Claude Code in the main (left) pane, Codex in the split
# (right) pane, both in ONE session. Upstream leaves starting Codex to the human; this script is the
# one deliberate departure, so Claude can bring in a peer on its own. The ONLY things it ever types
# are the codex launch line, into a shell prompt it has watched draw in a pane that was empty, and
# on --restart the one `/quit` line that ends the codex already running there, so a Codex started
# before a skill update can pick the update up.
#
# Codex strips AGTERM_SESSION_ID from its tool subprocesses, so the launch line re-injects the
# pane's session id through shell_environment_policy; without it peer-chat.py refuses a send
# whenever two sessions share the checkout.
#
# Exit codes: 0 codex runs in the right pane (already, or started here) — stdout carries one JSON
# line {"state":"already"|"started"|"restarted","session":ID}. 1 codex did not appear within
# start_timeout, or did not quit within it on --restart.
# 2 unreadable .peer-chat.json or bad usage. 3 a required tool is missing. 4 wrong place: outside
# agterm, this pane is not the main pane, or its foreground is not claude.
set -u

PLUGIN="peer-chat"
DEFAULT_CODEX_COMMAND="codex"
DEFAULT_CLAUDE_COMMAND="claude"
DEFAULT_START_TIMEOUT=30
SHELL_READY_TIMEOUT=5

die() {
	printf 'peer-chat-spawn: %s\n' "$1" >&2
	exit "$2"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- config --

profile_root() {
	git rev-parse --show-toplevel 2>/dev/null || pwd
}

load_profile() {
	PROFILE_FILE=""
	PROFILE_JSON="{}"
	local candidate
	candidate="$(profile_root)/.${PLUGIN}.json"
	[ -f "$candidate" ] || return 0
	PROFILE_JSON="$(jq -c . "$candidate" 2>/dev/null)" || die "unparseable ${candidate}" 2
	PROFILE_FILE="$candidate"
}

# resolve <key> <env-var> <default>: env wins, then the profile, then the default. Value and source
# come back joined by an ASCII unit separator, since tab is IFS whitespace and an empty value would
# collapse into its source on read.
SEP=$'\x1f'
resolve() {
	local key="$1" env_name="$2" fallback="$3" env_value profile_value
	env_value="${!env_name:-}"
	if [ -n "$env_value" ]; then
		printf '%s%sdetected:env:%s\n' "$env_value" "$SEP" "$env_name"
		return
	fi
	profile_value="$(printf '%s' "$PROFILE_JSON" | jq -r --arg k "$key" '.[$k] // empty')"
	if [ -n "$profile_value" ]; then
		printf '%s%sprofile\n' "$profile_value" "$SEP"
		return
	fi
	printf '%s%sdefault\n' "$fallback" "$SEP"
}

resolve_all() {
	load_profile
	IFS="$SEP" read -r CODEX_COMMAND CODEX_COMMAND_SRC <<<"$(resolve codex_command PEER_CHAT_CODEX_COMMAND "$DEFAULT_CODEX_COMMAND")"
	IFS="$SEP" read -r CODEX_ARGS CODEX_ARGS_SRC <<<"$(resolve codex_args PEER_CHAT_CODEX_ARGS "")"
	IFS="$SEP" read -r CLAUDE_COMMAND CLAUDE_COMMAND_SRC <<<"$(resolve claude_command PEER_CHAT_CLAUDE_COMMAND "$DEFAULT_CLAUDE_COMMAND")"
	IFS="$SEP" read -r START_TIMEOUT START_TIMEOUT_SRC <<<"$(resolve start_timeout PEER_CHAT_START_TIMEOUT "$DEFAULT_START_TIMEOUT")"
	case "$START_TIMEOUT" in
	'' | *[!0-9]*) die "start_timeout must be a whole number of seconds, got '${START_TIMEOUT}'" 2 ;;
	esac
}

explain() {
	resolve_all
	jq -n \
		--arg plugin "$PLUGIN" \
		--arg profile_file "$PROFILE_FILE" \
		--arg codex_command "$CODEX_COMMAND" --arg codex_command_src "$CODEX_COMMAND_SRC" \
		--arg codex_args "$CODEX_ARGS" --arg codex_args_src "$CODEX_ARGS_SRC" \
		--arg claude_command "$CLAUDE_COMMAND" --arg claude_command_src "$CLAUDE_COMMAND_SRC" \
		--argjson start_timeout "$START_TIMEOUT" --arg start_timeout_src "$START_TIMEOUT_SRC" \
		'{
		  plugin: $plugin,
		  profile_file: (if $profile_file == "" then null else $profile_file end),
		  values: {
		    codex_command: $codex_command,
		    codex_args: $codex_args,
		    claude_command: $claude_command,
		    start_timeout: $start_timeout
		  },
		  sources: {
		    codex_command: $codex_command_src,
		    codex_args: $codex_args_src,
		    claude_command: $claude_command_src,
		    start_timeout: $start_timeout_src
		  }
		}'
}

# ------------------------------------------------------------------ agterm --

session_node() {
	agtermctl tree --json | jq -c --arg s "$AGTERM_SESSION_ID" \
		'.. | objects | select(.id? == $s and (has("foreground") or has("splitForeground") or has("cwd")))' |
		head -n 1
}

# pane_runs <field> <command>: the same match peer-chat.py applies — the bare command name as a
# whole argv word, or as the last path component of one.
pane_runs() {
	local field="$1" command="$2"
	session_node | jq -e --arg f "$field" --arg c "$command" \
		'(.[$f] // []) | map(tostring) | any(test("(^|[/\\s])" + $c + "($|\\s)"))' \
		>/dev/null 2>&1
}

has_split() {
	session_node | jq -e '.hasSplit == true' >/dev/null 2>&1
}

split_visible() {
	session_node | jq -e '.split == true' >/dev/null 2>&1
}

split_busy() {
	session_node | jq -e '(.splitForeground // []) | length > 0' >/dev/null 2>&1
}

require_place() {
	[ "${AGTERM_ENABLED:-}" = "1" ] || die "not inside agterm (AGTERM_ENABLED unset)" 4
	[ -n "${AGTERM_SESSION_ID:-}" ] || die "no AGTERM_SESSION_ID: the quick terminal has no session" 4
	case "${AGTERM_PANE:-left}" in
	left) ;;
	*) die "this shell is in the '${AGTERM_PANE}' pane; peer-chat needs Claude in the main (left) pane" 4 ;;
	esac
	pane_runs foreground "$CLAUDE_COMMAND" ||
		die "the main pane's foreground is not '${CLAUDE_COMMAND}'; set PEER_CHAT_CLAUDE_COMMAND for a wrapper" 4
}

require_tools() {
	have agtermctl || die "agtermctl not on PATH — agterm ▸ Help ▸ Install Command Line Tool…" 3
	have jq || die "jq not found (brew install jq)" 3
	have "$CODEX_COMMAND" || die "'${CODEX_COMMAND}' not on PATH — install the codex CLI or set PEER_CHAT_CODEX_COMMAND" 3
	have peer-chat.py || die "peer-chat.py not on PATH — run peer-chat-install.sh first" 3
}

report() {
	jq -n -c --arg state "$1" --arg session "$AGTERM_SESSION_ID" '{state: $state, session: $session}'
}

open_split() {
	agtermctl session split on --target "$AGTERM_SESSION_ID" >/dev/null || die "session split failed" 1
}

wait_for_shell_prompt() {
	local deadline=$((SECONDS + SHELL_READY_TIMEOUT))
	while [ "$SECONDS" -lt "$deadline" ]; do
		if [ -n "$(agtermctl session text --pane right --target "$AGTERM_SESSION_ID" 2>/dev/null | tr -d '[:space:]')" ]; then
			return 0
		fi
		sleep 0.2
	done
	die "the split pane drew no shell prompt within ${SHELL_READY_TIMEOUT}s" 1
}

launch_line() {
	printf '%s -c '"'"'shell_environment_policy.set.AGTERM_SESSION_ID="%s"'"'"'' "$CODEX_COMMAND" "$AGTERM_SESSION_ID"
	[ -n "$CODEX_ARGS" ] && printf ' %s' "$CODEX_ARGS"
	printf '\n'
}

type_launch_line() {
	launch_line | agtermctl session type --stdin --pane right --target "$AGTERM_SESSION_ID" >/dev/null ||
		die "typing the launch line failed" 1
	agtermctl session focus left --target "$AGTERM_SESSION_ID" >/dev/null 2>&1 || true
}

wait_for_codex_gone() {
	local deadline=$((SECONDS + START_TIMEOUT))
	while [ "$SECONDS" -lt "$deadline" ]; do
		pane_runs splitForeground "$CODEX_COMMAND" || return 0
		sleep 0.5
	done
	die "'${CODEX_COMMAND}' is still the right pane's foreground ${START_TIMEOUT}s after /quit; read it with: agtermctl session text --pane right --target ${AGTERM_SESSION_ID}" 1
}

quit_codex() {
	printf '/quit\n' | agtermctl session type --stdin --pane right --target "$AGTERM_SESSION_ID" >/dev/null ||
		die "typing /quit failed" 1
	wait_for_codex_gone
}

wait_for_codex() {
	local deadline=$((SECONDS + START_TIMEOUT))
	while [ "$SECONDS" -lt "$deadline" ]; do
		pane_runs splitForeground "$CODEX_COMMAND" && return 0
		sleep 0.5
	done
	die "'${CODEX_COMMAND}' did not appear in the right pane within ${START_TIMEOUT}s; read it with: agtermctl session text --pane right --target ${AGTERM_SESSION_ID}" 1
}

restart_codex_pane() {
	if ! has_split || ! pane_runs splitForeground "$CODEX_COMMAND"; then
		ensure_codex_pane
		return
	fi
	split_visible || open_split
	quit_codex
	wait_for_shell_prompt
	type_launch_line
	wait_for_codex
	report restarted
}

ensure_codex_pane() {
	if has_split && pane_runs splitForeground "$CODEX_COMMAND"; then
		split_visible || open_split
		report already
		return
	fi
	if has_split && split_busy; then
		die "the right pane is busy running something that is not '${CODEX_COMMAND}'; close it or move it first" 1
	fi
	split_visible || open_split
	wait_for_shell_prompt
	type_launch_line
	wait_for_codex
	report started
}

main() {
	case "${1:-}" in
	--explain)
		have jq || die "jq not found — required for --explain (brew install jq)" 3
		explain
		;;
	'')
		resolve_all
		require_tools
		require_place
		ensure_codex_pane
		;;
	--restart)
		resolve_all
		require_tools
		require_place
		restart_codex_pane
		;;
	*) die "usage: peer-chat-spawn.sh [--restart|--explain]" 2 ;;
	esac
}

main "$@"
