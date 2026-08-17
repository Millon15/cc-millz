#!/bin/sh
# agterm-pin-resume — keep this agterm pane's restore command pinned to the LIVE Claude session,
# so a reboot or agterm relaunch reattaches the conversation instead of opening a bare shell.
#
# Wired as a SessionStart hook.
#
# WHY a hook and not a one-off pin: `agtermctl session restore` is STICKY — it re-fires on every
# restart until cleared. Written once by hand it would stay pinned to a stale session id forever.
# The hook rewrites it on every start, so the pin always tracks the session you are actually in.
#
# WHY this works despite `claude` being in restore-denylist.conf: a per-pane pin BYPASSES the
# denylist by design (it names its command deliberately). The denylist entry still protects
# un-pinned panes from fresh-starting a blank `claude`.
#
# Escape hatch — stop a pane from resurrecting its session:
#   agtermctl session restore --none  --target "$AGTERM_SESSION_ID"   # plain shell next launch
#   agtermctl session restore --clear --target "$AGTERM_SESSION_ID"   # back to auto-capture
#
# Hook contract: SessionStart stdout is injected into the prompt context and a non-zero exit can
# block the turn — so this is silent and always exits 0.
set -u

. "$(dirname "$0")/lib.sh"

inside_agterm || exit 0
# A headless `claude -p` child (ralphex, revmux) inherits this pane's AGTERM_SESSION_ID and would
# otherwise re-pin the pane to its own throwaway session id.
headless_claude && exit 0

sid=$(session_id_from_stdin) || exit 0

set -- session restore "claude --resume $sid" --target "$AGTERM_SESSION_ID"
[ -n "${AGTERM_PANE_ID:-}" ] && set -- "$@" --pane-id "$AGTERM_PANE_ID"

ctl "$@" >/dev/null 2>&1 || true
exit 0
