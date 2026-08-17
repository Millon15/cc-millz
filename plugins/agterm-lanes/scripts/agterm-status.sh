#!/bin/sh
# agterm-status — set this agterm session's agent-status indicator, replaying the lane's glyph.
#
#   agterm-status.sh active --blink       # agent is busy
#   agterm-status.sh completed --auto-reset
#   agterm-status.sh blocked              # agent is waiting on you
#   agterm-status.sh idle                 # clear the indicator
#
# States: idle | active | completed | blocked. Any further args are forwarded verbatim to
# `agtermctl session status`.
#
# WHY this ships here rather than reusing agterm's own agent-status hook: `--shape` rides a SINGLE
# status call and reverts on the next one without it, so the lane's silhouette has to be replayed on
# EVERY status or it is lost the moment the agent changes state. Patching that replay into agterm's
# installer-written script works until the next agterm upgrade silently overwrites it.
#
# Hue is deliberately left alone: that is the state palette (active/blocked/completed), and role
# already owns the shape.
#
# Outside agterm this is a silent no-op, so it is safe to call from any hook. As a hook it must
# never interfere with the agent: stdout/stderr are suppressed (Claude Code injects a
# UserPromptSubmit/SessionStart hook's stdout into the prompt context) and it always exits 0.
set -u

. "$(dirname "$0")/lib.sh"

inside_agterm || exit 0
headless_claude && exit 0

state=$1
shift

lane_shape() {
	shape_file="$LANE_STATE_DIR/shape-$AGTERM_SESSION_ID"
	[ -r "$shape_file" ] || return 1
	read -r shape <"$shape_file" 2>/dev/null || return 1
	case "$shape" in
	circle | square | triangle | diamond | capsule | star) printf '%s' "$shape" ;;
	*) return 1 ;;
	esac
}

shape=$(lane_shape) && set -- "$@" --shape "$shape"

ctl session status "$state" --target "$AGTERM_SESSION_ID" "$@" >/dev/null 2>&1 || true
exit 0
