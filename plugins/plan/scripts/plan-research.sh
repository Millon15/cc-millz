#!/usr/bin/env bash
# plan-research — run /plan:research headless, so an agent that is not this Claude session can
# ask for a proof and read the artifacts: Codex in a peer-chat pane, a CI job, a script.
#
#   plan-research.sh "<question>" [--slug <name>]   # run the pipeline, print the answer, exit 0
#   plan-research.sh --slug <name> --verify <n>      # re-run proof <n> against its proof.json contract
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
#
# --verify re-runs one proof the proover left under <artifacts_dir>/<slug>/: it reads
# <n>-proof.json (the contract: the run command, the cases with their expected values, the
# artifact and raw output paths), runs the command, parses the `PROOF <case>: <got>` lines the
# artifact prints, and compares. The run is appended to <n>-proof.runs.tsv with the tree sha and
# the sha256 of the contract, so a silently edited oracle shows as a new hash. A revision of an
# expectation is only accepted with its case, old_expect, new_expect, requirement and reviewer.
# Exit codes in this mode: 0 every case matches, 1 a regression (cases listed), 2 the artifact
# failed to run, 3 no usable contract. A proof without a contract is INCONCLUSIVE, never "fixed".
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

# ---------------------------------------------------------------- verify --

proof_dir() {
	printf '%s/%s/%s' "$(profile_root)" "$ARTIFACTS_DIR" "$1"
}

load_contract() {
	local file="$1"
	[ -f "$file" ] || die "no contract: ${file} is missing; a proof without it is INCONCLUSIVE" 3
	CONTRACT="$(jq -c . "$file" 2>/dev/null)" || die "no contract: ${file} is not JSON" 3
	[ "$(contract_query '[.cases[]? | select(.case != null and .expect != null)] | length')" -gt 0 ] ||
		die "no contract: ${file} has no case with both case and expect" 3
	[ -n "$(contract_query '.run // empty')" ] || die "no contract: ${file} has no run command" 3
	[ "$(contract_query '[.revisions[]? | select((.case and (.old_expect != null) and (.new_expect != null) and .requirement and .reviewer) | not)] | length')" -eq 0 ] ||
		die "no contract: ${file} has a revision missing case, old_expect, new_expect, requirement or reviewer" 3
}

contract_query() {
	printf '%s' "$CONTRACT" | jq -r "$1"
}

file_sha() {
	if have sha256sum; then
		sha256sum "$1" | cut -c1-64
	else
		shasum -a 256 "$1" | cut -c1-64
	fi
}

tree_sha() {
	git -C "$(profile_root)" rev-parse HEAD 2>/dev/null || printf 'no-git'
}

run_artifact() {
	local run="$1" out="$2"
	(cd "$(profile_root)" && bash -c "$run") >"$out" 2>&1 ||
		die "execution failure: '${run}' exited non-zero; output in ${out}" 2
}

got_for() {
	awk -v n="PROOF ${1}: " 'index($0, n) == 1 { print substr($0, length(n) + 1) }' "$2" | tail -n 1
}

list_regressions() {
	local out="$1" name expect got
	while IFS=$'\t' read -r name expect; do
		got="$(got_for "$name" "$out")"
		[ -n "$got" ] || got="<no PROOF line>"
		[ "$got" = "$expect" ] || printf 'regression: %s: expect %s, got %s\n' "$name" "$expect" "$got"
	done < <(contract_query '.cases[] | [.case, (.expect | tostring)] | @tsv')
}

print_revisions() {
	contract_query '.revisions[]? | "revision: \(.case): expect \(.old_expect) -> \(.new_expect); \(.requirement); reviewed by \(.reviewer)"'
}

record_run() {
	printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" >>"$1"
}

verify_proof() {
	local slug="$1" n="$2" dir contract out regressions tree contract_sha status=0
	[ -n "$slug" ] && [ -n "$n" ] || die "usage: plan-research.sh --slug <name> --verify <n>" 2
	resolve_all
	have jq || die "jq not found (brew install jq)" 3
	dir="$(proof_dir "$slug")"
	contract="${dir}/${n}-proof.json"
	out="${dir}/${n}-proof.verify.out"
	load_contract "$contract"
	tree="$(tree_sha)"
	contract_sha="$(file_sha "$contract")"
	print_revisions
	run_artifact "$(contract_query .run)" "$out"
	regressions="$(list_regressions "$out")"
	[ -z "$regressions" ] || status=1
	record_run "${dir}/${n}-proof.runs.tsv" "$tree" "$contract_sha" "$status"
	[ "$status" -eq 0 ] || {
		printf '%s\n' "$regressions"
		die "regression in ${ARTIFACTS_DIR}/${slug}/${n}-proof.json; tree ${tree}; contract ${contract_sha}" 1
	}
	say "verified ${ARTIFACTS_DIR}/${slug}/${n}-proof.json: $(contract_query '.cases | length') cases match; tree ${tree}; contract ${contract_sha}; output ${ARTIFACTS_DIR}/${slug}/${n}-proof.verify.out"
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
	'' | --help | -h) die "usage: plan-research.sh \"<question>\" [--slug <name>] | --slug <name> --verify <n> | --explain | --install | --check" 2 ;;
	esac
	local verify=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--slug)
			[ -n "${2:-}" ] || die "--slug needs a value" 2
			slug="$2"
			shift 2
			;;
		--verify)
			[ -n "${2:-}" ] || die "--verify needs the proof number" 2
			verify="$2"
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
	if [ -n "$verify" ]; then
		[ -z "$question" ] || die "--verify takes no question" 2
		verify_proof "$slug" "$verify"
		return
	fi
	run_research "$question" "$slug"
}

main "$@"
