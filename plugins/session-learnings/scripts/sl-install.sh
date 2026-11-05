#!/usr/bin/env bash
# sl-install.sh: switch the background worker on or off on this Mac (launchd agent + store layout).
#
# The SessionEnd hook only queues; nothing calls an LLM until this script installs the agent.
#   sl-install.sh            create the store, write the shim and the plist, load the agent
#   sl-install.sh --check    exit 0 when the agent plist exists and launchctl knows the label
#   sl-install.sh --uninstall  unload the agent and remove its plist; the store is kept
#   sl-install.sh --explain  print resolved config as JSON, no side effects
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="io.github.millon15.session-learnings"

usage() {
	echo "usage: sl-install.sh [--check|--uninstall|--explain]" >&2
	exit 64
}

main() {
	resolve_config
	case "${1:-install}" in
	install) install_agent ;;
	--check) check_agent ;;
	--uninstall) uninstall_agent ;;
	--explain) explain ;;
	*) usage ;;
	esac
}

resolve_config() {
	STORE="${SESSION_LEARNINGS_HOME:-$HOME/.claude/learnings}"
	STORE_SOURCE="$(source_of SESSION_LEARNINGS_HOME)"
	AGENTS_DIR="${SESSION_LEARNINGS_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
	AGENTS_SOURCE="$(source_of SESSION_LEARNINGS_LAUNCH_AGENTS)"
	MODEL="${SESSION_LEARNINGS_MODEL:-claude-opus-5-5}"
	MODEL_SOURCE="$(source_of SESSION_LEARNINGS_MODEL)"
	PLIST="$AGENTS_DIR/$LABEL.plist"
	SHIM="$STORE/bin/sl-run"
}

source_of() {
	[ -n "${!1:-}" ] && echo "detected:$1" || echo "default"
}

explain() {
	jq -n --arg store "$STORE" --arg ss "$STORE_SOURCE" --arg agents "$AGENTS_DIR" --arg as "$AGENTS_SOURCE" \
		--arg model "$MODEL" --arg ms "$MODEL_SOURCE" --arg root "$PLUGIN_ROOT" --arg label "$LABEL" '{
		plugin: "session-learnings",
		profile_file: null,
		values: {store: $store, launch_agents_dir: $agents, model: $model, plugin_root: $root, label: $label},
		sources: {store: $ss, launch_agents_dir: $as, model: $ms, plugin_root: "detected:script-location", label: "default"}
	}'
}

install_agent() {
	create_store
	write_shim
	render_plist
	reload_agent
	echo "session-learnings: worker agent $LABEL loaded; store $STORE"
}

create_store() {
	mkdir -p "$STORE"/{queue,processing,done,failed,work,tmp,bin}
	[ -f "$STORE/.since" ] || touch "$STORE/.since"
	printf '%s\n' "$PLUGIN_ROOT" >"$STORE/plugin-root"
}

# launchd keeps one fixed path; the shim follows plugin-root, which every SessionEnd refreshes.
# The shim has no paths baked in: the plist hands it SESSION_LEARNINGS_HOME.
write_shim() {
	cat >"$SHIM" <<'SHIM'
#!/bin/bash
root="$(cat "${SESSION_LEARNINGS_HOME:?}/plugin-root" 2>/dev/null)"
[ -x "$root/scripts/sl-worker.sh" ] || { echo "sl-run: no worker under '$root'" >&2; exit 78; }
exec /bin/bash "$root/scripts/sl-worker.sh" "$@"
SHIM
	chmod +x "$SHIM"
}

# launchd does not inherit this shell, so every worker override set now is written into the plist.
render_plist() {
	mkdir -p "$AGENTS_DIR"
	python3 - "$PLIST" "$LABEL" "$SHIM" "$STORE" <<'PY'
import os, plistlib, sys
plist, label, shim, store = sys.argv[1:5]
passed = ["PATH", "CLAUDE_CONFIG_DIR", "SESSION_LEARNINGS_MODEL", "SESSION_LEARNINGS_EXTRACTOR",
          "SESSION_LEARNINGS_TIMEOUT", "SESSION_LEARNINGS_MIN_HUMAN", "SESSION_LEARNINGS_TEXT_LIMIT",
          "SESSION_LEARNINGS_SWEEP_IDLE_MINUTES", "SESSION_LEARNINGS_DIGEST_BUDGET",
          "SESSION_LEARNINGS_NOTIFY"]
env = {name: os.environ[name] for name in passed if os.environ.get(name)}
env["SESSION_LEARNINGS_HOME"] = store
agent = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", shim],
    "QueueDirectories": [os.path.join(store, "queue")],
    "StartInterval": 3600,
    "RunAtLoad": False,
    "ProcessType": "Background",
    "LowPriorityIO": True,
    "EnvironmentVariables": env,
    "StandardOutPath": os.path.join(store, "launchd.out"),
    "StandardErrorPath": os.path.join(store, "launchd.err"),
}
with open(plist, "wb") as out:
    plistlib.dump(agent, out)
PY
	plutil -lint "$PLIST" >/dev/null
}

reload_agent() {
	launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" "$PLIST"
}

check_agent() {
	[ -f "$PLIST" ] || {
		echo "session-learnings: no plist at $PLIST" >&2
		return 1
	}
	launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || {
		echo "session-learnings: $LABEL not loaded" >&2
		return 1
	}
	echo "session-learnings: $LABEL loaded"
}

uninstall_agent() {
	launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	[ -f "$PLIST" ] && rm -f "$PLIST"
	echo "session-learnings: $LABEL unloaded; store kept at $STORE"
}

main "$@"
