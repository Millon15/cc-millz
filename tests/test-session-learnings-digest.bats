#!/usr/bin/env bats
#
# tests/test-session-learnings-digest.bats: sl-digest.sh derives each row's class from the
# transcript alone, redacts before it truncates; sl-signal.sh nominates sessions.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	SCRIPTS="${REPO_ROOT}/plugins/session-learnings/scripts"
	FIXTURES="${REPO_ROOT}/tests/fixtures/session-learnings"
}

teardown() { teardown_tmp; }

class_at() {
	jq -r --argjson n "$2" 'select(.line == $n) | .class' "$1"
}

@test "classes come from the transcript: human, exec_error, exec_ok, read, assistant" {
	"$SCRIPTS/sl-digest.sh" "$FIXTURES/transcripts/fix-cycle.jsonl" >"$TMP/d.jsonl"
	[ "$(class_at "$TMP/d.jsonl" 1)" = human ]
	[ "$(class_at "$TMP/d.jsonl" 2)" = assistant ]
	[ "$(class_at "$TMP/d.jsonl" 3)" = exec_error ]
	[ "$(class_at "$TMP/d.jsonl" 5)" = read ]
	[ "$(class_at "$TMP/d.jsonl" 6)" = human ]
	[ "$(class_at "$TMP/d.jsonl" 8)" = exec_ok ]
}

@test "a peer-chat paste and an unlinked tool result are read, never human or exec_ok" {
	"$SCRIPTS/sl-digest.sh" "$FIXTURES/transcripts/fix-cycle.jsonl" >"$TMP/d.jsonl"
	[ "$(class_at "$TMP/d.jsonl" 10)" = read ]
	[ "$(class_at "$TMP/d.jsonl" 11)" = read ]
}

@test "meta rows and unparseable lines are dropped, line numbers stay 1-based transcript lines" {
	"$SCRIPTS/sl-digest.sh" "$FIXTURES/transcripts/fix-cycle.jsonl" >"$TMP/d.jsonl"
	[ -z "$(class_at "$TMP/d.jsonl" 9)" ]
	[ -z "$(class_at "$TMP/d.jsonl" 13)" ]
	[ "$(jq -r 'select(.line == 12) | .text' "$TMP/d.jsonl")" = "good, works now" ]
}

@test "the committed digest fixture matches what sl-digest.sh produces today" {
	"$SCRIPTS/sl-digest.sh" "$FIXTURES/transcripts/fix-cycle.jsonl" >"$TMP/d.jsonl"
	diff "$FIXTURES/digests/fix-cycle.digest.jsonl" "$TMP/d.jsonl"
}

@test "secrets are scrubbed before truncation, so no prefix of a secret survives the cut" {
	local filler
	filler="$(printf 'x%.0s' $(seq 1 490))"
	jq -nc --arg t "$filler password=SUPERSECRETVALUE" \
		'{type:"user",entrypoint:"cli",origin:{kind:"human"},message:{content:$t}}' >"$TMP/t.jsonl"
	SESSION_LEARNINGS_TEXT_LIMIT=500 "$SCRIPTS/sl-digest.sh" "$TMP/t.jsonl" >"$TMP/d.jsonl"
	[ "$(jq -r '.text | length' "$TMP/d.jsonl")" -eq 500 ]
	! grep -q 'SUPER' "$TMP/d.jsonl"
}

@test "signal: a fix window with three human turns nominates the session" {
	run "$SCRIPTS/sl-signal.sh" "$FIXTURES/digests/fix-cycle.digest.jsonl"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.fix_window' <<<"$output")" = true ]
}

@test "signal: a two-turn chat is not worth an extractor call" {
	"$SCRIPTS/sl-digest.sh" "$FIXTURES/transcripts/short.jsonl" >"$TMP/d.jsonl"
	run "$SCRIPTS/sl-signal.sh" "$TMP/d.jsonl"
	[ "$status" -eq 1 ]
	[ "$(jq -r '.signal' <<<"$output")" = false ]
}

@test "signal: the human-turn floor follows SESSION_LEARNINGS_MIN_HUMAN" {
	SESSION_LEARNINGS_MIN_HUMAN=4 run "$SCRIPTS/sl-signal.sh" "$FIXTURES/digests/fix-cycle.digest.jsonl"
	[ "$status" -eq 1 ]
}

@test "over the byte budget, human and Bash rows are kept before reads and prose" {
	SESSION_LEARNINGS_DIGEST_BUDGET=400 "$SCRIPTS/sl-digest.sh" "$FIXTURES/transcripts/fix-cycle.jsonl" >"$TMP/d.jsonl"
	[ "$(wc -c <"$TMP/d.jsonl" | tr -d ' ')" -le 400 ]
	[ "$(class_at "$TMP/d.jsonl" 8)" = exec_ok ]
	[ "$(class_at "$TMP/d.jsonl" 12)" = human ]
	! jq -e 'select(.class == "read" or .class == "assistant")' "$TMP/d.jsonl" >/dev/null
	[ "$(jq -s 'map(.line) == (map(.line) | sort)' "$TMP/d.jsonl")" = true ]
}
