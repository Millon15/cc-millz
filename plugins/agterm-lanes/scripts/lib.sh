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
