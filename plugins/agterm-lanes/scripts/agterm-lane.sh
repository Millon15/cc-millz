#!/bin/sh
# agterm-lane — name and tint this agterm lane once, from Claude's own session title.
#
# Wired on TWO events, first one to fire wins the lane:
#
#   Stop                                    — type a bare `/rename`, wait for Claude to publish the
#                                             new title over OSC, then mirror it onto the lane.
#   PreToolUse AskUserQuestion|ExitPlanMode — LANE_TYPE_RENAME=0: adopt the auto-title as-is.
#
# WHY the second trigger: a turn that asks the user something does NOT end, so it emits no Stop. A
# session can spend its whole life parked on one unanswered question and never get named.
#
# Load-bearing constraints, each learned the hard way:
#
#   `--shape` rides ONE status call and reverts on the next without it, so it cannot just be set
#   here. It is persisted per pane and replayed by agterm-status.sh on every status it sets.
#
#   Role owns the glyph SILHOUETTE, never its hue: hue is the state palette
#   (active/blocked/completed). If role took both channels, turn state would have no signal left.
#
#   `session type` sends a REAL Return, and Stop fires exactly when a follow-up may be half-typed —
#   hence the idle guard. On the PreToolUse path a question dialog is on screen and a keystroke
#   would ANSWER it, so that path never types.
#
#   Every exit path is a silent exit 0 (Stop stdout lands in the transcript), so a failure is
#   indistinguishable from a no-op without the breadcrumb log.
#
#   The claim is keyed on the PANE, not on Claude's session id: a headless `claude -p` child
#   (ralphex, revmux) inherits the pane's AGTERM_* and mints a fresh session id per run, so a
#   session-keyed claim was free on every run and each one typed `/rename` into the pane the
#   interactive Claude owns. Those children are also refused outright (lib.sh headless_claude).
#
#   A `/rename <name>` the user typed wins: the transcript is checked for one before typing, and a
#   found one is adopted as-is — a bare `/rename` would regenerate the title over theirs.
#
# Undo:   agtermctl session rename "<x>" ; agtermctl session background clear
# Re-run: delete ~/.claude/agterm-lanes/lane-<AGTERM_SESSION_ID>
set -u

LANE_TYPE_RENAME=${LANE_TYPE_RENAME:-1} # 0 = adopt Claude's auto-title, never inject keystrokes
LANE_IDLE_MIN_MS=${LANE_IDLE_MIN_MS:-4000}
LANE_TITLE_WAIT_S=${LANE_TITLE_WAIT_S:-20}
LANE_TYPE_RETRIES=${LANE_TYPE_RETRIES:-3}

. "$(dirname "$0")/lib.sh"

LANE_LOG="$LANE_STATE_DIR/lane-debug.log"

log() {
	printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LANE_LOG" 2>/dev/null
	return 0
}

claim_once() {
	sentinel="$LANE_STATE_DIR/lane-$1"
	[ -e "$sentinel" ] && return 1
	mkdir -p "$LANE_STATE_DIR" 2>/dev/null
	: >"$sentinel"
	lane_already_named && return 1
	return 0
}

# A sentinel can be lost (state dir wiped, key scheme changed) — the role emoji the lane already
# wears is the durable witness that it was named.
lane_already_named() {
	case "$(current_name)" in
	🐛* | 🚀* | 🔍* | 🧪* | 🧹* | 🔧* | 📊* | 📝* | 💬*) return 0 ;;
	esac
	return 1
}

pane_field() {
	ctl tree --json 2>/dev/null |
		jq -r --arg s "$AGTERM_SESSION_ID" --arg f "$1" \
			'.result.tree.workspaces[].sessions[] | select(.id==$s) | .[$f] // ""' 2>/dev/null
}

current_name() {
	pane_field name
}

# The claim is taken before the slow work so a rename cannot fire twice. That makes any bail
# PERMANENT unless the claim is handed back, so a transient obstacle must release it.
release_claim() {
	mv "$sentinel" "$sentinel.retry" 2>/dev/null
}

# Claude prefixes its title with a live status glyph (✳ ⠐ ⠂ …) that changes as it works.
current_title() {
	pane_field title | sed 's/^[^[:alnum:]]*//'
}

window_idle_ms() {
	idle=$(ctl tree --json 2>/dev/null | jq -r '.result.tree.idleMs // 0' 2>/dev/null)
	case "$idle" in '' | *[!0-9]*) idle=0 ;; esac
	printf '%s' "$idle"
}

session_is_selected() {
	ctl tree --json 2>/dev/null |
		jq -e --arg s "$AGTERM_SESSION_ID" \
			'[.result.tree.workspaces[].sessions[] | select(.id==$s) | .active] | first == true' \
			>/dev/null 2>&1
}

type_rename() {
	printf '/rename\n' | ctl session type --stdin --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
}

# idleMs is WINDOW-scoped, but the question is session-scoped: "is a draft half-typed in THIS
# prompt box?". A background lane cannot hold a draft the user is editing, so guarding it on window
# idleness blocked every lane that finished while the user worked in a different one.
type_rename_when_safe() {
	session_is_selected || {
		type_rename
		return 0
	}
	n=0
	while [ "$n" -lt "$LANE_TYPE_RETRIES" ]; do
		[ "$(window_idle_ms)" -ge "$LANE_IDLE_MIN_MS" ] && {
			type_rename
			return 0
		}
		n=$((n + 1))
		sleep 3
	done
	log "RETRY: selected lane still busy, releasing claim"
	release_claim
	return 1
}

await_title_change() {
	was=$1
	waited=0
	while [ "$waited" -lt "$LANE_TITLE_WAIT_S" ]; do
		sleep 1
		waited=$((waited + 1))
		now=$(current_title)
		[ -z "$now" ] && continue
		[ "$now" = "$was" ] && continue
		[ "$now" = "Claude Code" ] && continue
		printf '%s' "$now"
		return 0
	done
	return 1
}

# Pascal-Dash-Case, max 5 words. Any separator is a word boundary, so "handle subscription refunds"
# and "handle-subscription-refunds" land on the same shape.
normalise() {
	printf '%s' "$1" | tr -c '[:alnum:]' ' ' | awk '{
        out = ""; n = 0
        for (i = 1; i <= NF && n < 5; i++) {
            w = toupper(substr($i, 1, 1)) tolower(substr($i, 2))
            out = (out == "" ? w : out "-" w); n++
        }
        print out
    }' | cut -c1-40
}

infer_role() {
	case " $(printf '%s' "$1" | tr '[:upper:]-' '[:lower:] ') " in
	*" bug "* | *fix* | *error* | *crash* | *broken* | *debug* | *fail*) printf 'bug' ;;
	*review* | *" pr "* | *rubric* | *feedback* | *comment*) printf 'review' ;;
	*test* | *" qa "* | *spec* | *coverage* | *e2e*) printf 'test' ;;
	*refactor* | *cleanup* | *prune* | *simplify* | *migrat* | *restructur*) printf 'refactor' ;;
	*deploy* | *release* | *rollout* | *publish* | *" prod "*) printf 'deploy' ;;
	*config* | *setup* | *" hook "* | *" hooks "* | *install* | *setting* | *plugin* | *wiring*) printf 'config' ;;
	*data* | *query* | *sql* | *mongo* | *clickhouse* | *metric* | *report* | *analytic*) printf 'data' ;;
	*doc* | *readme* | *guide* | *changelog*) printf 'docs' ;;
	*) printf 'other' ;;
	esac
}

# Tints are dark but genuinely chromatic (~10% luminance) so the hue reads without hurting terminal
# text contrast. Six silhouettes cover nine roles, so shapes group by class rather than map 1:1:
# triangle = can break prod · diamond = verification · square = hygiene · capsule = information.
# `star` is left unassigned, free to mark a lane by hand.
role_style() {
	case "$1" in
	bug) emoji="🐛" tint="#3b1218" shape="triangle" ;;
	deploy) emoji="🚀" tint="#45101c" shape="triangle" ;;
	review) emoji="🔍" tint="#3a2a0d" shape="diamond" ;;
	test) emoji="🧪" tint="#0d2f33" shape="diamond" ;;
	refactor) emoji="🧹" tint="#2a1140" shape="square" ;;
	config) emoji="🔧" tint="#10233f" shape="square" ;;
	data) emoji="📊" tint="#10321f" shape="capsule" ;;
	docs) emoji="📝" tint="#33113a" shape="capsule" ;;
	*) emoji="💬" tint="#1c1c22" shape="circle" ;;
	esac
}

apply_lane() {
	ctl session rename "$emoji $1" --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
	rc_name=$?
	ctl session background color "$tint" --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
	rc_bg=$?
	printf '%s\n' "$shape" >"$LANE_STATE_DIR/shape-$AGTERM_SESSION_ID" 2>/dev/null
	ctl session status active --shape "$shape" --target "$AGTERM_SESSION_ID" >/dev/null 2>&1
	log "$emoji $1 [$tint $shape] rename=$rc_name bg=$rc_bg"
}

# A slash command lands in the transcript as `<command-name>/rename</command-name> …
# <command-args>NAME</command-args>`; a bare `/rename` (ours included) carries empty args.
user_renamed_manually() {
	[ -n "$transcript" ] && [ -r "$transcript" ] || return 1
	grep -qE 'command-name>/rename</command-name>.{0,120}<command-args>[^<]' "$transcript" 2>/dev/null
}

should_type_rename() {
	[ "$LANE_TYPE_RENAME" = "1" ] || return 1
	user_renamed_manually || return 0
	log "manual /rename found, adopting the title as-is"
	return 1
}

main() {
	inside_agterm || exit 0
	headless_claude && exit 0
	transcript=$(transcript_path_from_stdin)
	claim_once "$AGTERM_SESSION_ID" || exit 0

	# Claude auto-titles a session even without /rename, so the live title is already a usable name;
	# only waiting on a title we asked for is worth blocking on.
	before=$(current_title)
	title=$before
	if should_type_rename; then
		type_rename_when_safe || exit 0
		title=$(await_title_change "$before") || title=$before
	fi

	case "$title" in
	'' | 'Claude Code')
		log "RETRY: no usable title yet, releasing claim"
		release_claim
		exit 0
		;;
	esac

	name=$(normalise "$title")
	[ -n "$name" ] || exit 0
	role_style "$(infer_role "$name")"
	apply_lane "$name"
}

main
exit 0
