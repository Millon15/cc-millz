#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "$REPO_ROOT/tests/helpers/common.bash"
    setup_tmp
    SCRIPTS="$REPO_ROOT/plugins/session-learnings/scripts"
    FIX="$REPO_ROOT/tests/fixtures/session-learnings/lifecycle-right"
    python3 "$FIX/seed.py" "$TMP/store"
    mkdir -p "$TMP/projects/-example-project"
    TRANSCRIPT="$TMP/projects/-example-project/session.jsonl"
}
teardown() { teardown_tmp; }
scan() {
    python3 "$FIX/transcript.py" "$1" > "$TRANSCRIPT"
    "$SCRIPTS/sl-apply.sh" --store="$TMP/store" --session=session1 --transcript="$TRANSCRIPT"
}

@test "recall then Bash success emits applied and applied_ok accepted idempotently by C2" {
    scan success > "$TMP/events"
    [ "$(jq -sr 'map(.type)|join(",")' "$TMP/events")" = applied,applied_ok ]
    "$SCRIPTS/sl-ledger.sh" events --store="$TMP/store" < "$TMP/events"
    "$SCRIPTS/sl-ledger.sh" events --store="$TMP/store" < "$TMP/events"
    [ "$("$SCRIPTS/sl-ledger.sh" list --store="$TMP/store" | jq 'select(.claim|startswith("Always")) | .counts.applied_ok')" = 1 ]
}

@test "same normalized preceding error recurs after recall and overrides an intervening success" {
    run scan failure
    assert_status 0
    [ "$(jq -sr 'map(.type)|join(",")' <<< "$output")" = applied,applied_fail ]
}

@test "unrelated failure or a Read success does not claim an outcome" {
    for scenario in unrelated-failure read-after; do
        run scan "$scenario"
        assert_status 0
        [ "$(jq -sr 'map(.type)|join(",")' <<< "$output")" = applied ]
    done
}

@test "Skill use matches only promoted names" {
    run scan skill
    assert_status 0
    [ "$(jq -r .type <<< "$output")" = applied ]
    [ "$(jq -r .id <<< "$output")" = "lsn-$(printf 'f%.0s' {1..64})" ]
    run scan unknown-skill
    assert_status 0
    [ -z "$output" ]
}

@test "Read output echoed recall commands assistant claims and sidechains cannot spoof an application" {
    for scenario in spoof sidechain; do
        run scan "$scenario"
        assert_status 0
        [ -z "$output" ]
    done
}

@test "repeated exposures yield one pair of events and unreadable transcripts fail" {
    run scan repeated
    assert_status 0
    [ "$(jq -s length <<< "$output")" = 2 ]
    run "$SCRIPTS/sl-apply.sh" --store="$TMP/store" --session=x --transcript="$TMP/missing"
    assert_status 2
}
