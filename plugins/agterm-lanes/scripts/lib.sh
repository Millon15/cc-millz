#!/bin/sh
# Shared plumbing for the agterm-lanes hooks. Sourced, never executed.
#
# AGTERM_SOCKET contains a space (".../Application Support/..."), so it can never be reassembled
# into a "--socket $VAR" string and splatted unquoted. ctl() is the only way these hooks talk to
# agtermctl.
#
# agtermctl resolution order: an explicit $AGTERMCTL override, then the bundled binary (present even
# when the CLI was never symlinked into PATH), then PATH.

AGTERMCTL=${AGTERMCTL:-/Applications/agterm.app/Contents/MacOS/agtermctl}
[ -x "$AGTERMCTL" ] || AGTERMCTL=agtermctl

# Sentinels and glyph records outlive the plugin: ${CLAUDE_PLUGIN_ROOT} is a cache directory that is
# wiped and re-copied on every version bump, which would re-name every open lane after an update.
# shellcheck disable=SC2034  # read by the sourcing hook, not here
LANE_STATE_DIR=${AGTERM_LANE_STATE_DIR:-$HOME/.claude/agterm-lanes}

ctl() {
	if [ -n "${AGTERM_SOCKET:-}" ]; then
		"$AGTERMCTL" "$@" --socket "$AGTERM_SOCKET"
	else
		"$AGTERMCTL" "$@"
	fi
}

inside_agterm() {
	[ -n "${AGTERM_SESSION_ID:-}" ]
}

# A pin is persisted shell code and a sentinel is a filename, so a session id is only ever trusted
# when it is UUID-shaped.
session_id_from_stdin() {
	sid=$(jq -r '.session_id // empty' 2>/dev/null)
	case "$sid" in
	[0-9a-fA-F]*-*-*-*-*) printf '%s' "$sid" ;;
	*) return 1 ;;
	esac
}

transcript_path_from_stdin() {
	jq -r '.transcript_path // empty' 2>/dev/null
}

# A headless `claude -p` child (ralphex, revmux, any `--print` run started from a Bash tool)
# inherits the pane's AGTERM_* and mints a fresh session id per run, so its hooks would rename,
# re-pin and re-tint the pane the interactive Claude owns. The child's env carries no marker
# (CLAUDECODE is scrubbed so it can start at all), so the nearest `claude` ancestor's argv is the
# only witness. No claude ancestor within reach = fail-open, treated as interactive.
headless_claude() {
	pid=$PPID
	depth=0
	while [ "$depth" -lt 8 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
		argv=$(ps -o command= -p "$pid" 2>/dev/null)
		is_claude_argv "$argv" && {
			is_headless_argv "$argv"
			return
		}
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		depth=$((depth + 1))
	done
	return 1
}

is_claude_argv() {
	case "$1" in
	claude | claude\ * | */claude | */claude\ *) return 0 ;;
	esac
	return 1
}

is_headless_argv() {
	case " $1 " in
	*" -p "* | *" --print "* | *" --output-format "* | *" --output-format="*) return 0 ;;
	esac
	return 1
}
