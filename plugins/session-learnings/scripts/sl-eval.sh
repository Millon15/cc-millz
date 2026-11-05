#!/usr/bin/env bash
# sl-eval.sh: run several extractor arms (model + prompt) on the same recent sessions and write a blind sheet.
#
# Usage: sl-eval.sh --out=DIR --arm=NAME:MODEL:PROMPT [--arm=...] [--sessions=10] [--exclude=SESSION_ID]
# Picks the newest interactive transcripts that pass the signal gate, runs every arm on each digest, then writes:
#   costs.tsv   arm, session, usd, seconds, lessons
#   blind.md    per session, the arms' lessons under shuffled labels X, Y, Z...
#   key.json    {session: {label: arm}}, kept apart so a grader can read blind.md without it
# Every arm call is a real model call and costs money; nothing touches the learnings store.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
LABELS=(X Y Z U V W)
OUT="" SESSIONS=10 EXCLUDE="" ARMS=()

main() {
	parse_args "$@"
	mkdir -p "$OUT"/{digests,arms}
	select_sessions >"$OUT/sessions.tsv"
	run_arms
	write_costs
	write_blind_sheet
	echo "sl-eval: $(wc -l <"$OUT/sessions.tsv" | tr -d ' ') sessions x ${#ARMS[@]} arms in $OUT"
	report_failures
}

report_failures() {
	local failed
	failed="$(awk -F'\t' 'NR > 1 && $3 == "failed"' "$OUT/costs.tsv" | wc -l | tr -d ' ')"
	[ "$failed" -eq 0 ] && return 0
	echo "sl-eval: $failed arm calls failed; they show as (extraction failed) in blind.md" >&2
	return 1
}

usage() {
	echo "usage: sl-eval.sh --out=DIR --arm=NAME:MODEL:PROMPT [--arm=...] [--sessions=N] [--exclude=ID]" >&2
	exit 64
}

parse_args() {
	local arg
	for arg in "$@"; do
		case "$arg" in
		--out=*) OUT="${arg#--out=}" ;;
		--arm=*) ARMS+=("${arg#--arm=}") ;;
		--sessions=*) SESSIONS="${arg#--sessions=}" ;;
		--exclude=*) EXCLUDE="${arg#--exclude=}" ;;
		*) usage ;;
		esac
	done
	[ -n "$OUT" ] && [ "${#ARMS[@]}" -ge 1 ] && [ "${#ARMS[@]}" -le "${#LABELS[@]}" ] || usage
	[[ "$SESSIONS" =~ ^[1-9][0-9]?$ ]] || usage
	check_arms
	check_fresh_out
}

# Results are keyed by arm name and session, so a reused name or directory would mix two runs.
check_fresh_out() {
	[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || {
		echo "sl-eval: $OUT is not empty; give a fresh --out" >&2
		exit 64
	}
}

check_arms() {
	local arm name model prompt
	for arm in "${ARMS[@]}"; do
		IFS=: read -r name model prompt <<<"$arm"
		[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] && [ -n "$model" ] && [ -r "$prompt" ] || {
			echo "sl-eval: bad arm '$arm'" >&2
			exit 64
		}
	done
	[ -z "$(arm_names | sort | uniq -d)" ] || {
		echo "sl-eval: arm names must be unique" >&2
		exit 64
	}
}

# Prints "session_id<TAB>project<TAB>transcript" for the newest sessions with signal.
select_sessions() {
	local transcript session_id found=0
	while IFS= read -r transcript; do
		session_id="$(basename "$transcript" .jsonl)"
		[ "$session_id" = "$EXCLUDE" ] && continue
		is_eligible "$session_id" "$transcript" || continue
		printf '%s\t%s\t%s\n' "$session_id" "$(basename "$(dirname "$transcript")")" "$transcript"
		found=$((found + 1))
		[ "$found" -lt "$SESSIONS" ] || return 0
	done < <(newest_transcripts)
}

newest_transcripts() {
	find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name '*.jsonl' -print0 2>/dev/null |
		xargs -0 stat -f '%m %N' | sort -rn | cut -d' ' -f2-
}

is_eligible() {
	local digest="$OUT/digests/$1.jsonl"
	is_interactive "$2" || return 1
	"$SCRIPTS_DIR/sl-digest.sh" "$2" >"$digest" 2>/dev/null &&
		"$SCRIPTS_DIR/sl-signal.sh" "$digest" >/dev/null 2>&1 && return 0
	rm -f -- "$digest"
	return 1
}

is_interactive() {
	local entrypoint
	entrypoint="$(jq -r 'select(.entrypoint) | .entrypoint' "$1" 2>/dev/null | head -n 1)"
	[ "$entrypoint" = cli ] || [ "$entrypoint" = claude-desktop ]
}

# Arms of one session run in parallel; sessions run one after another.
run_arms() {
	local session_id arm
	while IFS=$'\t' read -r session_id _ _; do
		for arm in "${ARMS[@]}"; do
			run_arm "$session_id" "$arm" &
		done
		wait
	done <"$OUT/sessions.tsv"
}

run_arm() {
	local session_id="$1" name model prompt base started
	IFS=: read -r name model prompt <<<"$2"
	base="$OUT/arms/$name.$session_id"
	started="$(date +%s)"
	CLAUDE_LEARN_SKIP=1 SESSION_LEARNINGS_MODEL="$model" "$SCRIPTS_DIR/sl-extract.sh" \
		--digest="$OUT/digests/$session_id.jsonl" --prompt="$prompt" --usage="$base.usage.json" \
		>"$base.json" 2>/dev/null || echo '{"lessons":[],"failed":true}' >"$base.json"
	echo $(($(date +%s) - started)) >"$base.seconds"
}

write_costs() {
	local session_id arm name
	printf 'arm\tsession\tusd\tseconds\tlessons\n' >"$OUT/costs.tsv"
	while IFS=$'\t' read -r session_id _ _; do
		for arm in "${ARMS[@]}"; do
			name="${arm%%:*}"
			cost_row "$name" "$session_id" >>"$OUT/costs.tsv"
		done
	done <"$OUT/sessions.tsv"
}

cost_row() {
	local base="$OUT/arms/$1.$2" usd
	usd="$(jq -r '.total_cost_usd // "na"' "$base.usage.json" 2>/dev/null || echo na)"
	jq -e '.failed' "$base.json" >/dev/null && usd=failed
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$usd" "$(cat "$base.seconds")" "$(jq '.lessons | length' "$base.json")"
}

write_blind_sheet() {
	local session_id project index=0
	echo '{}' >"$OUT/key.json"
	echo "# Blind sheet: $(wc -l <"$OUT/sessions.tsv" | tr -d ' ') sessions" >"$OUT/blind.md"
	while IFS=$'\t' read -r session_id project _; do
		index=$((index + 1))
		blind_session "$index" "$session_id" "$project" >>"$OUT/blind.md"
	done <"$OUT/sessions.tsv"
}

# shellcheck disable=SC2016 # backticks are markdown
blind_session() {
	local index="$1" session_id="$2" project="$3" position=0 name
	printf '\n## Session %s\n\nproject `%s`, digest `digests/%s.jsonl`\n' "$index" "$project" "$session_id"
	while IFS= read -r name; do
		blind_arm "${LABELS[$position]}" "$OUT/arms/$name.$session_id.json"
		record_key "$session_id" "${LABELS[$position]}" "$name"
		position=$((position + 1))
	done < <(arm_names | sort -R)
}

arm_names() {
	local arm
	for arm in "${ARMS[@]}"; do
		echo "${arm%%:*}"
	done
}

blind_arm() {
	printf '\n### %s\n\n' "$1"
	jq -r 'if .failed then "(extraction failed)" elif (.lessons | length) == 0 then "(no lessons)" else
		.lessons | to_entries[] | "\(.key + 1). [\(.value.kind), \(.value.scope), line \(.value.evidence_line)]\n" +
		"   trigger: \(.value.trigger)\n   claim: \(.value.claim)" end' "$2"
}

record_key() {
	jq --arg s "$1" --arg l "$2" --arg a "$3" '.[$s][$l] = $a' "$OUT/key.json" >"$OUT/key.json.tmp"
	mv -f "$OUT/key.json.tmp" "$OUT/key.json"
}

main "$@"
