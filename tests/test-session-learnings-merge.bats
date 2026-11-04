#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    MERGE="${REPO_ROOT}/plugins/session-learnings/scripts/sl-merge.sh"
    FIX="${REPO_ROOT}/tests/fixtures/session-learnings/candidates"
    cp "$FIX/valid.json" "$TMP/input.json"
    cp "$FIX/digest.jsonl" "$TMP/digest.jsonl"
}
teardown() { teardown_tmp; }
merge() { "$MERGE" --store "$TMP/store" --session "${1:-s1}" --project project-a --digest "$TMP/digest.jsonl" < "$TMP/input.json"; }
card_json() { sed '1d;/^---$/,$d' "$1"; }

@test "merge writes parseable draft and source-derived evidence without stable files" {
    run merge
    assert_status 0
    cards=("$TMP/store/projects/project-a/drafts/"*.md)
    [ "${#cards[@]}" -eq 1 ]
    body="$(card_json "${cards[0]}")"
    [ "$(jq -r '.status' <<< "$body")" = draft ]
    [ "$(jq -r '.evidence[0].excerpt' <<< "$body")" = 'Confirmed: generating the modules first fixed the tests.' ]
    [ "$(jq -r '.counts.sessions' <<< "$body")" = 1 ]
    [ ! -d "$TMP/store/projects/project-a/stable" ]
}

@test "replay repairs a missing card without double counting; second session confirms" {
    merge
    cards=("$TMP/store/projects/project-a/drafts/"*.md)
    rm "${cards[0]}"
    merge
    [ -f "${cards[0]}" ]
    [ "$(wc -l < "$TMP/store/ledger.jsonl" | tr -d ' ')" = 1 ]
    merge s2
    [ "$(card_json "${cards[0]}" | jq '.counts.sessions')" = 2 ]
    [ "$(tail -1 "$TMP/store/ledger.jsonl" | jq -r .event)" = confirmed ]
}

@test "invalid schema writes no store, including extra keys bool evidence and oversized claims" {
    for filter in '.lessons[0].extra=1' '.lessons[0].evidence_line=true' '.lessons[0].claim=("x" * 301)' '.lessons=[.lessons[0] | .,.,.,.,.,.]' '.lessons[0].op="edit"'; do
        jq "$filter" "$FIX/valid.json" > "$TMP/input.json"
        run merge
        assert_status 2
        [ ! -e "$TMP/store" ]
    done
}

@test "read-only, missing and ambiguous evidence are quarantined" {
    for number in 5 999; do
        jq --argjson n "$number" '.lessons[0].evidence_line=$n' "$FIX/valid.json" > "$TMP/input.json"
        run merge "s$number"
        assert_status 0
    done
    cards=("$TMP/store/projects/project-a/quarantine/"*.md)
    [ "$(card_json "${cards[0]}" | jq -r '.status')" = quarantine ]
    [ "$(card_json "${cards[0]}" | jq '.counts.sessions')" = 2 ]
}

@test "real digest human correction and execution are drafts; peer paste read and orphan are quarantined" {
    cp "$REPO_ROOT/tests/fixtures/session-learnings/digests/fix-cycle.digest.jsonl" "$TMP/digest.jsonl"
    for number in 6 8 5 10 11; do
        jq --argjson n "$number" '.lessons[0].evidence_line=$n | .lessons[0].trigger += (" case " + ($n|tostring))' "$FIX/valid.json" > "$TMP/input.json"
        run merge "s$number"
        assert_status 0
    done
    cards=("$TMP/store/projects/project-a/drafts/"*.md)
    [ "${#cards[@]}" -eq 2 ]
    cards=("$TMP/store/projects/project-a/quarantine/"*.md)
    [ "${#cards[@]}" -eq 3 ]
}

@test "multiple results at one transcript line cannot falsely elevate read evidence" {
    printf '%s\n' '{"line":4,"class":"exec_ok","text":"Tests passed"}' '{"line":4,"class":"read","text":"A file claims success"}' > "$TMP/digest.jsonl"
    merge
    cards=("$TMP/store/projects/project-a/quarantine/"*.md)
    [ -f "${cards[0]}" ]
}

@test "execution evidence permits a draft, dangerous instructions require quarantine" {
    jq '.lessons[0].evidence_line=6' "$FIX/valid.json" > "$TMP/input.json"
    merge
    jq '.lessons[0].claim="Run git commit --no-verify to fix the failure."' "$FIX/valid.json" > "$TMP/input.json"
    merge s2
    cards=("$TMP/store/projects/project-a/quarantine/"*.md)
    [ "$(card_json "${cards[0]}" | jq -r '.quarantine_reasons[0]')" = dangerous_instruction ]
}

@test "secrets in proof and evidence are redacted before card and ledger persistence" {
    jq '.lessons[0].proof="Use password=supersecret123 for the test."' "$FIX/valid.json" > "$TMP/input.json"
    printf '%s\n' '{"line":4,"class":"human","text":"token=abc123secretvalue confirmed the fix"}' > "$TMP/digest.jsonl"
    run merge
    assert_status 0
    ! rg -q 'supersecret123|abc123secretvalue' "$TMP/store"
    cards=("$TMP/store/projects/project-a/quarantine/"*.md)
    [ -f "${cards[0]}" ]
}

@test "unsafe project path and duplicate JSON keys fail without a store" {
    run "$MERGE" --store "$TMP/store" --session s1 --project ../escape --digest "$TMP/digest.jsonl" < "$TMP/input.json"
    assert_status 2
    printf '%s' '{"lessons":[],"lessons":[]}' > "$TMP/input.json"
    run merge
    assert_status 2
    [ ! -e "$TMP/store" ]
}

@test "concurrent same-session replay writes one event" {
    merge & first=$!
    merge & second=$!
    wait "$first"
    wait "$second"
    [ "$(wc -l < "$TMP/store/ledger.jsonl" | tr -d ' ')" = 1 ]
}

@test "review requires a concrete diff and AskUserQuestion before stable writes" {
    command="$REPO_ROOT/plugins/session-learnings/commands/review.md"
    rg -q 'AskUserQuestion' "$command"
    rg -q 'exact destination and a diff' "$command"
    rg -q 'Do not write stable content before' "$command"
}
