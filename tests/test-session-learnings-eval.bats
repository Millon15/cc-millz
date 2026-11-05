#!/usr/bin/env bats
# sl-eval.sh: picks the newest interactive sessions with signal, runs every arm, writes a blind sheet and its key.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	EVAL="${REPO_ROOT}/plugins/session-learnings/scripts/sl-eval.sh"
	FIXTURES="${REPO_ROOT}/tests/fixtures/session-learnings"
	export CLAUDE_CONFIG_DIR="$TMP/config" FIX="$FIXTURES/candidates"
	export SESSION_LEARNINGS_EXTRACTOR="$STUB_BIN/extractor"
	stub extractor 'printf "%s\n" "$@" >> "$TMP/calls"; jq '\''{is_error:false,total_cost_usd:0.01,structured_output:.}'\'' "$FIX/valid.json"'
	add_session -proj s-old fix-cycle 202601010000
	add_session -proj s-new fix-cycle 202601020000
	add_session -proj s-headless headless 202601030000
	add_session -proj s-current fix-cycle 202601040000
	printf 'prompt one\n' >"$TMP/p1.md"
	printf 'prompt two\n' >"$TMP/p2.md"
}
teardown() { teardown_tmp; }

add_session() {
	mkdir -p "$CLAUDE_CONFIG_DIR/projects/$1"
	cp "$FIXTURES/transcripts/$3.jsonl" "$CLAUDE_CONFIG_DIR/projects/$1/$2.jsonl"
	touch -t "$4" "$CLAUDE_CONFIG_DIR/projects/$1/$2.jsonl"
}

run_eval() {
	run "$EVAL" --out="$TMP/out" --sessions=5 --exclude=s-current \
		--arm=alpha:model-a:"$TMP/p1.md" --arm=beta:model-b:"$TMP/p2.md"
}

@test "eval keeps interactive sessions with signal, newest first, and skips the excluded one" {
	run_eval
	assert_status 0
	[ "$(cut -f1 "$TMP/out/sessions.tsv" | paste -sd, -)" = "s-new,s-old" ]
}

@test "every arm runs on every session with its own model and prompt" {
	run_eval
	[ "$(grep -c '^model-a$' "$TMP/calls")" = 2 ]
	[ "$(grep -c '^model-b$' "$TMP/calls")" = 2 ]
	[ "$(grep -c '^prompt two$' "$TMP/calls")" = 2 ]
	[ "$(wc -l <"$TMP/out/costs.tsv" | tr -d ' ')" = 5 ]
	[ "$(awk -F'\t' '$1=="beta" && $2=="s-new" {print $3"/"$5}' "$TMP/out/costs.tsv")" = "0.01/1" ]
}

@test "blind sheet hides arm names; the key maps each label back to one arm" {
	run_eval
	! grep -qE 'alpha|beta|model-' "$TMP/out/blind.md"
	grep -q '^### X$' "$TMP/out/blind.md"
	[ "$(jq -c '.["s-new"] | [.[]] | sort' "$TMP/out/key.json")" = '["alpha","beta"]' ]
}

@test "a bad arm is refused before any model call" {
	run "$EVAL" --out="$TMP/out" --arm=alpha:model-a:"$TMP/missing.md"
	assert_status 64
	[ ! -e "$TMP/calls" ]
}
