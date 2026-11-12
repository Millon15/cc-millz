#!/usr/bin/env bash
# sl-install.sh: switch the background agents on or off on this Mac (launchd agents + store layout).
#
# The SessionEnd hook only queues; nothing calls an LLM until this script installs the worker agent.
#   sl-install.sh                 create the store, write the worker shim and plist, load the worker agent
#   sl-install.sh --review-weekly the same, plus the weekly agent that opens /session-learnings:review in agterm
#   sl-install.sh --check         exit 0 when the worker is loaded and the review agent, if installed, is too
#   sl-install.sh --uninstall     unload both agents and remove their plists; the store is kept
#   sl-install.sh --explain       print resolved config as JSON, no side effects
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="io.github.millon15.session-learnings"
REVIEW_LABEL="$LABEL.review"
WORKER_ENV=(PATH CLAUDE_CONFIG_DIR SESSION_LEARNINGS_MODEL SESSION_LEARNINGS_EXTRACTOR SESSION_LEARNINGS_TIMEOUT
	SESSION_LEARNINGS_MIN_HUMAN SESSION_LEARNINGS_TEXT_LIMIT SESSION_LEARNINGS_SWEEP_IDLE_MINUTES
	SESSION_LEARNINGS_DIGEST_BUDGET SESSION_LEARNINGS_NOTIFY)
REVIEW_ENV=(PATH CLAUDE_CONFIG_DIR SESSION_LEARNINGS_NOTIFY)

usage() {
	echo "usage: sl-install.sh [--review-weekly|--check|--uninstall|--explain]" >&2
	exit 64
}

main() {
	resolve_config
	case "${1:-install}" in
	install) install_worker ;;
	--review-weekly) install_worker && install_review ;;
	--check) check_agents ;;
	--uninstall) uninstall_agents ;;
	--explain) explain ;;
	*) usage ;;
	esac
}

resolve_config() {
	STORE="${SESSION_LEARNINGS_HOME:-$HOME/.claude/learnings}"
	AGENTS_DIR="${SESSION_LEARNINGS_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
	MODEL="${SESSION_LEARNINGS_MODEL:-claude-opus-5-5}"
	REVIEW_WEEKDAY="${SESSION_LEARNINGS_REVIEW_WEEKDAY:-1}"
	REVIEW_HOUR="${SESSION_LEARNINGS_REVIEW_HOUR:-10}"
	REVIEW_CWD="${SESSION_LEARNINGS_REVIEW_CWD:-$HOME}"
	PLIST="$AGENTS_DIR/$LABEL.plist"
	REVIEW_PLIST="$AGENTS_DIR/$REVIEW_LABEL.plist"
	SHIM="$STORE/bin/sl-run"
	REVIEW_SHIM="$STORE/bin/sl-review"
}

source_of() {
	[ -n "${!1:-}" ] && echo "detected:$1" || echo "default"
}

explain() {
	jq -n --arg store "$STORE" --arg ss "$(source_of SESSION_LEARNINGS_HOME)" \
		--arg agents "$AGENTS_DIR" --arg as "$(source_of SESSION_LEARNINGS_LAUNCH_AGENTS)" \
		--arg model "$MODEL" --arg ms "$(source_of SESSION_LEARNINGS_MODEL)" \
		--arg weekday "$REVIEW_WEEKDAY" --arg ws "$(source_of SESSION_LEARNINGS_REVIEW_WEEKDAY)" \
		--arg hour "$REVIEW_HOUR" --arg hs "$(source_of SESSION_LEARNINGS_REVIEW_HOUR)" \
		--arg cwd "$REVIEW_CWD" --arg cs "$(source_of SESSION_LEARNINGS_REVIEW_CWD)" \
		--arg root "$PLUGIN_ROOT" --arg label "$LABEL" --arg rlabel "$REVIEW_LABEL" '{
		plugin: "session-learnings",
		profile_file: null,
		values: {store: $store, launch_agents_dir: $agents, model: $model, plugin_root: $root, label: $label,
			review_label: $rlabel, review_weekday: $weekday, review_hour: $hour, review_cwd: $cwd},
		sources: {store: $ss, launch_agents_dir: $as, model: $ms, plugin_root: "detected:script-location",
			label: "default", review_label: "default", review_weekday: $ws, review_hour: $hs, review_cwd: $cs}
	}'
}

install_worker() {
	create_store
	write_shim "$SHIM" sl-worker.sh
	worker_agent | write_plist "$PLIST"
	reload_agent "$LABEL" "$PLIST"
	echo "session-learnings: worker agent $LABEL loaded; store $STORE"
}

install_review() {
	validate_schedule
	write_shim "$REVIEW_SHIM" sl-review-launch.sh
	review_agent | write_plist "$REVIEW_PLIST"
	reload_agent "$REVIEW_LABEL" "$REVIEW_PLIST"
	echo "session-learnings: review agent $REVIEW_LABEL loaded; weekday $REVIEW_WEEKDAY at $REVIEW_HOUR:00 in $REVIEW_CWD"
}

validate_schedule() {
	in_range "$REVIEW_WEEKDAY" 0 7 && in_range "$REVIEW_HOUR" 0 23 && return 0
	echo "sl-install: SESSION_LEARNINGS_REVIEW_WEEKDAY must be 0-7 and SESSION_LEARNINGS_REVIEW_HOUR 0-23" >&2
	exit 64
}

in_range() {
	[[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

create_store() {
	mkdir -p "$STORE"/{queue,processing,done,failed,work,tmp,bin}
	[ -f "$STORE/.since" ] || touch "$STORE/.since"
	printf '%s\n' "$PLUGIN_ROOT" >"$STORE/plugin-root"
}

# launchd keeps one fixed path; the shim follows plugin-root, which every SessionEnd refreshes.
# The shim has no paths baked in: the plist hands it SESSION_LEARNINGS_HOME.
write_shim() {
	local shim="$1" script="$2" name
	name="$(basename "$1")"
	cat >"$shim" <<SHIM
#!/bin/bash
root="\$(cat "\${SESSION_LEARNINGS_HOME:?}/plugin-root" 2>/dev/null)"
[ -x "\$root/scripts/$script" ] || { echo "$name: no $script under '\$root'" >&2; exit 78; }
exec /bin/bash "\$root/scripts/$script" "\$@"
SHIM
	chmod +x "$shim"
}

worker_agent() {
	agent_env "${WORKER_ENV[@]}" | jq --arg label "$LABEL" --arg shim "$SHIM" --arg store "$STORE" '{
		Label: $label,
		ProgramArguments: ["/bin/bash", $shim],
		QueueDirectories: [$store + "/queue"],
		StartInterval: 3600,
		RunAtLoad: false,
		ProcessType: "Background",
		LowPriorityIO: true,
		EnvironmentVariables: .,
		StandardOutPath: ($store + "/launchd.out"),
		StandardErrorPath: ($store + "/launchd.err")
	}'
}

review_agent() {
	agent_env "${REVIEW_ENV[@]}" | jq --arg label "$REVIEW_LABEL" --arg shim "$REVIEW_SHIM" --arg store "$STORE" \
		--arg cwd "$REVIEW_CWD" --argjson weekday "$REVIEW_WEEKDAY" --argjson hour "$REVIEW_HOUR" '{
		Label: $label,
		ProgramArguments: ["/bin/bash", $shim],
		StartCalendarInterval: {Weekday: $weekday, Hour: $hour, Minute: 0},
		RunAtLoad: false,
		ProcessType: "Interactive",
		EnvironmentVariables: (. + {SESSION_LEARNINGS_REVIEW_CWD: $cwd}),
		StandardOutPath: ($store + "/review.out"),
		StandardErrorPath: ($store + "/review.err")
	}'
}

# launchd does not inherit this shell, so every override set now is written into the plist.
agent_env() {
	jq -n --arg store "$STORE" '$ARGS.positional
		| map({key: ., value: env[.]}) | map(select((.value // "") != ""))
		| from_entries + {SESSION_LEARNINGS_HOME: $store}' --args "$@"
}

write_plist() {
	mkdir -p "$AGENTS_DIR"
	python3 -c 'import json, plistlib, sys; plistlib.dump(json.load(sys.stdin), open(sys.argv[1], "wb"))' "$1"
	plutil -lint "$1" >/dev/null
}

reload_agent() {
	launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" "$2"
}

check_agents() {
	check_agent "$LABEL" "$PLIST" || return 1
	[ -f "$REVIEW_PLIST" ] || {
		echo "session-learnings: review agent not installed (opt in with --review-weekly)"
		return 0
	}
	check_agent "$REVIEW_LABEL" "$REVIEW_PLIST"
}

check_agent() {
	[ -f "$2" ] || {
		echo "session-learnings: no plist at $2" >&2
		return 1
	}
	launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1 || {
		echo "session-learnings: $1 not loaded" >&2
		return 1
	}
	echo "session-learnings: $1 loaded"
}

uninstall_agents() {
	local label
	for label in "$LABEL" "$REVIEW_LABEL"; do
		launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
		rm -f "$AGENTS_DIR/$label.plist"
	done
	echo "session-learnings: $LABEL and $REVIEW_LABEL unloaded; store kept at $STORE"
}

main "$@"
