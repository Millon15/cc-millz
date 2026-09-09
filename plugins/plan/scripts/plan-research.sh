#!/usr/bin/env bash
# plan-research — run /plan:research headless, so an agent that is not this Claude session can
# ask for a proof and read the artifacts: Codex in a peer-chat pane, a CI job, a script.
#
#   plan-research.sh "<question>" [--slug <name>]   # run the pipeline, print the answer, exit 0
#   plan-research.sh --explain                       # print the resolved config as JSON, change nothing
#   plan-research.sh --install                       # write the launcher onto PATH
#   plan-research.sh --check                         # exit 0 when the launcher is in place
#
# The run is `claude -p "/plan:research slug=<slug> <question>"` with every MCP server off
# (--strict-mcp-config with no --mcp-config): a headless child that boots the project's servers
# pays their startup on every call and opens a browser tab for any server never authorized.
# Permissions stay Claude's: the default is `--permission-mode acceptEdits`, which lets the
# subagents write their artifacts and denies any Bash command the project has not allow-listed;
# a project that wants the proover to run its containers widens that through `claude_args` in
# its committed .plan.json, never here.
#
# Exit codes: 0 answer written. 1 claude exited non-zero (its stderr is passed through).
# 2 bad usage or an unparseable .plan.json. 3 a required tool is missing.
set -u

PLUGIN="plan"
DEFAULT_CLAUDE_COMMAND="claude"
DEFAULT_CLAUDE_ARGS="--permission-mode acceptEdits"
DEFAULT_ARTIFACTS_DIR="tmp/a"
DEFAULT_TIMEOUT=1500

BIN_DIR="${PLAN_BIN_DIR:-$HOME/.local/bin}"
CACHE_GLOB="${PLAN_CACHE_DIR:-$HOME/.claude/plugins/cache/cc-millz/plan}"

say() { printf 'plan-research: %s\n' "$1"; }
die() {
	printf 'plan-research: %s\n' "$1" >&2
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

# resolve <key> <env-var> <default>: env wins, then the profile, then the default. Joined by an
# ASCII unit separator so an empty value cannot collapse into its source on read.
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
	IFS="$SEP" read -r CLAUDE_COMMAND CLAUDE_COMMAND_SRC <<<"$(resolve claude_command PLAN_CLAUDE_COMMAND "$DEFAULT_CLAUDE_COMMAND")"
	IFS="$SEP" read -r CLAUDE_ARGS CLAUDE_ARGS_SRC <<<"$(resolve claude_args PLAN_CLAUDE_ARGS "$DEFAULT_CLAUDE_ARGS")"
	IFS="$SEP" read -r ARTIFACTS_DIR ARTIFACTS_DIR_SRC <<<"$(resolve artifacts_dir PLAN_ARTIFACTS_DIR "$DEFAULT_ARTIFACTS_DIR")"
	IFS="$SEP" read -r TIMEOUT TIMEOUT_SRC <<<"$(resolve timeout PLAN_RESEARCH_TIMEOUT "$DEFAULT_TIMEOUT")"
	case "$TIMEOUT" in
	'' | *[!0-9]*) die "timeout must be a whole number of seconds, got '${TIMEOUT}'" 2 ;;
	esac
}

explain() {
	resolve_all
	jq -n \
		--arg plugin "$PLUGIN" \
		--arg profile_file "$PROFILE_FILE" \
		--arg claude_command "$CLAUDE_COMMAND" --arg claude_command_src "$CLAUDE_COMMAND_SRC" \
		--arg claude_args "$CLAUDE_ARGS" --arg claude_args_src "$CLAUDE_ARGS_SRC" \
		--arg artifacts_dir "$ARTIFACTS_DIR" --arg artifacts_dir_src "$ARTIFACTS_DIR_SRC" \
		--argjson timeout "$TIMEOUT" --arg timeout_src "$TIMEOUT_SRC" \
		'{
		  plugin: $plugin,
		  profile_file: (if $profile_file == "" then null else $profile_file end),
		  values: {
		    claude_command: $claude_command,
		    claude_args: $claude_args,
		    artifacts_dir: $artifacts_dir,
		    timeout: $timeout
		  },
		  sources: {
		    claude_command: $claude_command_src,
		    claude_args: $claude_args_src,
		    artifacts_dir: $artifacts_dir_src,
		    timeout: $timeout_src
		  }
		}'
}

# ------------------------------------------------------------------- run --

slug_from() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-30 | sed 's/-$//'
}

timeout_prefix() {
	if have timeout; then
		printf 'timeout %s' "$TIMEOUT"
	elif have gtimeout; then
		printf 'gtimeout %s' "$TIMEOUT"
	fi
}

run_research() {
	local question="$1" slug="$2" out_dir answer prefix status
	[ -n "$question" ] || die "usage: plan-research.sh \"<question>\" [--slug <name>]" 2
	resolve_all
	have "$CLAUDE_COMMAND" || die "'${CLAUDE_COMMAND}' not on PATH; install Claude Code or set PLAN_CLAUDE_COMMAND" 3
	have jq || die "jq not found (brew install jq)" 3
	[ -n "$slug" ] || slug="$(slug_from "$question")"
	out_dir="$(profile_root)/${ARTIFACTS_DIR}/${slug}"
	mkdir -p "$out_dir" || die "cannot create ${out_dir}" 1
	answer="${out_dir}/answer.md"
	prefix="$(timeout_prefix)"
	say "running /plan:research slug=${slug} (artifacts: ${ARTIFACTS_DIR}/${slug}/)"
	# claude_args word-splits on purpose (several flags in one string); -f keeps a `Bash(docker:*)`
	# allow-list entry from being glob-expanded against the working directory.
	set -f
	# shellcheck disable=SC2086
	${prefix} "$CLAUDE_COMMAND" -p --strict-mcp-config --output-format text $CLAUDE_ARGS \
		"/plan:research slug=${slug} ${question}" | tee "$answer"
	status=${PIPESTATUS[0]}
	set +f
	[ "$status" -eq 0 ] || die "claude exited ${status}; partial answer in ${answer}" 1
	say "answer: ${ARTIFACTS_DIR}/${slug}/answer.md"
}

# --------------------------------------------------------------- install --

on_path() {
	case ":$PATH:" in
	*":$1:"*) return 0 ;;
	esac
	return 1
}

launcher_body() {
	cat <<EOF
#!/usr/bin/env bash
# plan-research launcher, written by plan@cc-millz's --install. Resolves the newest installed
# plugin copy at run time, so a plugin version bump never leaves a dangling path behind.
set -u
target="\$(ls -d "${CACHE_GLOB}"/*/scripts/plan-research.sh 2>/dev/null | sort -V | tail -n 1)"
[ -n "\$target" ] || { echo "plan-research: plan@cc-millz is not installed (claude plugin install plan@cc-millz)" >&2; exit 3; }
exec bash "\$target" "\$@"
EOF
}

install_launcher() {
	mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR" 1
	local target="$BIN_DIR/plan-research.sh"
	if [ -f "$target" ] && [ "$(cat "$target")" = "$(launcher_body)" ]; then
		say "unchanged $target"
	else
		launcher_body >"$target" || die "cannot write $target" 1
		say "wrote     $target"
	fi
	chmod +x "$target"
	on_path "$BIN_DIR" || say "WARN      add $BIN_DIR to PATH; peers call plan-research.sh by bare name"
	say "Codex asks for approval on every run; to change that, the user adds a rule to ~/.codex/rules/default.rules by hand"
}

check() {
	local missing=0
	if [ -x "$BIN_DIR/plan-research.sh" ] && [ "$(cat "$BIN_DIR/plan-research.sh")" = "$(launcher_body)" ]; then
		say "ok   $BIN_DIR/plan-research.sh"
	else
		say "MISSING or stale  $BIN_DIR/plan-research.sh"
		missing=1
	fi
	on_path "$BIN_DIR" || {
		say "WARN $BIN_DIR is not on PATH"
		missing=1
	}
	return "$missing"
}

main() {
	local question="" slug=""
	case "${1:-}" in
	--explain)
		have jq || die "jq not found; required for --explain (brew install jq)" 3
		explain
		return
		;;
	--install)
		install_launcher
		return
		;;
	--check)
		check
		return
		;;
	'' | --help | -h) die "usage: plan-research.sh \"<question>\" [--slug <name>] | --explain | --install | --check" 2 ;;
	esac
	while [ $# -gt 0 ]; do
		case "$1" in
		--slug)
			[ -n "${2:-}" ] || die "--slug needs a value" 2
			slug="$2"
			shift 2
			;;
		--*) die "unknown option $1" 2 ;;
		*)
			[ -z "$question" ] || die "one question only; quote it" 2
			question="$1"
			shift
			;;
		esac
	done
	run_research "$question" "$slug"
}

main "$@"
