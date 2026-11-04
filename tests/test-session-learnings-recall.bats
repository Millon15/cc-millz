#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "$REPO_ROOT/tests/helpers/common.bash"
    setup_tmp
    SCRIPTS="$REPO_ROOT/plugins/session-learnings/scripts"
    python3 "$REPO_ROOT/tests/fixtures/session-learnings/lifecycle-right/seed.py" "$TMP/store"
}
teardown() { teardown_tmp; }

@test "recall uses the real C3 view and exposes only this project and global candidates" {
    run "$SCRIPTS/sl-recall.sh" --store="$TMP/store" --project-dir=/example/project
    assert_status 0
    [ "$(jq -s length <<< "$output")" = 2 ]
    [ "$(jq -s '[.[]|select(.status=="candidate" and .unreviewed==true)]|length' <<< "$output")" = 2 ]
    assert_contains "$output" 'Always verify checksums'
    assert_contains "$output" 'empty suffix'
    assert_not_contains "$output" 'other project'
    assert_not_contains "$output" 'must never be recalled'
    assert_not_contains "$output" 'Regenerate'
}

@test "query ranks relevant candidates and honors the result limit" {
    run "$SCRIPTS/sl-recall.sh" --store="$TMP/store" --project-dir=/example/project --query='BSD sed in-place' --limit=1
    assert_status 0
    [ "$(jq -s length <<< "$output")" = 1 ]
    [ "$(jq -r .scope <<< "$output")" = global ]
    run "$SCRIPTS/sl-recall.sh" --store="$TMP/store" --project-dir=/example/project --query='unrelated astronomy'
    assert_status 0
    [ -z "$output" ]
}

@test "recall missing store is empty and never writes a ledger; invalid limit fails" {
    run "$SCRIPTS/sl-recall.sh" --store="$TMP/missing" --project-dir=/example/project
    assert_status 0
    [ -z "$output" ]
    [ ! -e "$TMP/missing/ledger.jsonl" ]
    run "$SCRIPTS/sl-recall.sh" --store="$TMP/store" --project-dir=/example/project --limit=0
    assert_status 2
}

@test "recall skill preserves the approval boundary and review records lifecycle decisions" {
    skill="$REPO_ROOT/plugins/session-learnings/skills/recall/SKILL.md"
    review="$REPO_ROOT/plugins/session-learnings/commands/review.md"
    rg -q 'allowed-tools: Bash\(bash \$\{CLAUDE_PLUGIN_ROOT\}/scripts/sl-recall.sh' "$skill"
    rg -Fq 'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/sl-recall.sh" *)' "$skill"
    rg -q 'unreviewed: true' "$skill"
    rg -q 'AskUserQuestion' "$review"
    rg -q -- '--type=promoted' "$review"
    rg -q -- '--type=deprecated' "$review"
    rg -q -- '--type=rejected' "$review"
    rg -q 'Do not write stable content before' "$review"
    rg -q 'Never edit `ledger.jsonl` by hand' "$review"
}
