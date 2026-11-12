#!/usr/bin/env bats
# sl-review-launch.sh against stubbed sl-stats.sh, sl-ledger.sh and agtermctl in a copied scripts dir.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	SCRIPTS="$TMP/plugin/scripts"
	mkdir -p "$SCRIPTS/lib"
	cp "$REPO_ROOT/plugins/session-learnings/scripts/sl-review-launch.sh" "$SCRIPTS/"
	cp "$REPO_ROOT/plugins/session-learnings/scripts/lib/sl_housekeeping.py" "$SCRIPTS/lib/"
	LAUNCH="$SCRIPTS/sl-review-launch.sh"
	export SESSION_LEARNINGS_HOME="$TMP/store" SESSION_LEARNINGS_REVIEW_CWD="$TMP/project"
	export SESSION_LEARNINGS_NOTIFY="$STUB_BIN/notifier"
	unset CLAUDE_LEARN_SKIP
	stub_stats
	stub_ledger
	stub_agtermctl
	stub notifier "printf '%s\n' \"\$1\" >> '$TMP/notify.log'"
	printf '%s' '{"result":{"tree":{"workspaces":[{"sessions":[]}]}}}' >"$TMP/tree.json"
}

teardown() { teardown_tmp; }

stub_stats() {
	cat >"$SCRIPTS/sl-stats.sh" <<STATS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMP/stats.log'
case "\$1" in
report) [ -e '$TMP/stats-fail' ] && exit 1; echo '$TMP/store/usage/2026-W46.json' ;;
proposals) cat '$TMP/proposals.jsonl' 2>/dev/null || true ;;
esac
STATS
	chmod +x "$SCRIPTS/sl-stats.sh"
}

stub_ledger() {
	cat >"$SCRIPTS/sl-ledger.sh" <<LEDGER
#!/usr/bin/env bash
cat '$TMP/ledger.jsonl' 2>/dev/null || true
LEDGER
	chmod +x "$SCRIPTS/sl-ledger.sh"
}

stub_agtermctl() {
	cat >"$STUB_BIN/agtermctl" <<AGTERM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMP/agterm.log'
case "\$1 \$2" in
"window list") [ -e '$TMP/agterm-down' ] && exit 1
	echo '{"result":{"windows":[{"id":"W1","open":true},{"id":"W2","open":false}]}}' ;;
"tree --json") cat '$TMP/tree.json' ;;
"session new") echo NEW-SESSION-ID ;;
esac
exit 0
AGTERM
	chmod +x "$STUB_BIN/agtermctl"
}

open_proposal() {
	echo '{"id":"prp-0123456789ab","kind":"knowledge-gap","status":"open"}' >"$TMP/proposals.jsonl"
}

launched() {
	grep -q '^session new' "$TMP/agterm.log" 2>/dev/null
}

@test "nothing to review skips without touching agterm" {
	run "$LAUNCH"
	assert_status 0
	[ "$output" = "skipped: nothing to review" ]
	! launched
	grep -q '^report --store=.* --if-stale$' "$TMP/stats.log"
}

@test "an open proposal launches one background session running the review" {
	open_proposal
	run "$LAUNCH"
	assert_status 0
	[ "$output" = "launched NEW-SESSION-ID" ]
	local new
	new="$(grep '^session new' "$TMP/agterm.log")"
	assert_contains "$new" "--cwd $TMP/project"
	assert_contains "$new" "--workspace-name session-learnings --create-workspace"
	assert_contains "$new" "--no-select"
	assert_contains "$new" "claude \"/session-learnings:review\""
	grep -q '^session status blocked --target NEW-SESSION-ID$' "$TMP/agterm.log"
	grep -q 'weekly review open' "$TMP/notify.log"
}

@test "a ready lesson candidate alone launches the review" {
	echo '{"id":"lsn-a","flags":["ready"]}' >"$TMP/ledger.jsonl"
	run "$LAUNCH"
	assert_status 0
	[ "$output" = "launched NEW-SESSION-ID" ]
}

@test "a candidate without the ready flag is not work" {
	echo '{"id":"lsn-a","flags":[]}' >"$TMP/ledger.jsonl"
	run "$LAUNCH"
	[ "$output" = "skipped: nothing to review" ]
}

@test "an open review found by its argv is not opened twice, whatever the session is named" {
	open_proposal
	printf '%s' '{"result":{"tree":{"workspaces":[{"sessions":[
		{"id":"OTHER","name":"x","foreground":["claude"]},
		{"id":"OPEN-ID","name":"renamed by a lane hook","foreground":["claude","/session-learnings:review"]}
	]}]}}}' >"$TMP/tree.json"
	run "$LAUNCH"
	assert_status 0
	[ "$output" = "skipped: review already open OPEN-ID" ]
	! launched
	! grep -q -- '--window W2' "$TMP/agterm.log"
}

@test "unreachable agterm falls back to a notification" {
	open_proposal
	touch "$TMP/agterm-down"
	run "$LAUNCH"
	assert_status 0
	[ "$output" = "notified: agterm unavailable" ]
	grep -q 'run /session-learnings:review' "$TMP/notify.log"
	! launched
}

@test "a failed usage report still reviews ready lessons" {
	touch "$TMP/stats-fail"
	echo '{"id":"lsn-a","flags":["ready"]}' >"$TMP/ledger.jsonl"
	run "$LAUNCH"
	assert_status 0
	assert_contains "$output" "launched NEW-SESSION-ID"
	assert_contains "$output" "usage report failed"
}

@test "dry run prints the command and opens nothing" {
	open_proposal
	run "$LAUNCH" --dry-run
	assert_status 0
	assert_contains "$output" "dry-run: agtermctl session new"
	! launched
}

@test "an unknown argument is a usage error and CLAUDE_LEARN_SKIP turns it off" {
	run "$LAUNCH" --bogus
	assert_status 64
	open_proposal
	CLAUDE_LEARN_SKIP=1 run "$LAUNCH"
	assert_status 0
	[ -z "$output" ]
	[ ! -e "$TMP/stats.log" ]
}
