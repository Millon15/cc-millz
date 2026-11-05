#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "$REPO_ROOT/tests/helpers/common.bash"
    setup_tmp
    SCRIPTS="$REPO_ROOT/plugins/session-learnings/scripts"
    python3 "$REPO_ROOT/tests/fixtures/session-learnings/lifecycle-right/seed.py" "$TMP/store"
    export SESSION_LEARNINGS_EXTRACTOR="$STUB_BIN/judge" JUDGE_LOG="$TMP/judge-call.json" JUDGE_RELATION=same
    export JUDGE_TARGET="lsn-$(printf 'a%.0s' {1..64})"
    export CLAUDECODE=nested
    cat > "$SESSION_LEARNINGS_EXTRACTOR" <<'STUB'
#!/usr/bin/env python3
import json, os, pathlib, sys
payload=json.load(sys.stdin)
pathlib.Path(os.environ['JUDGE_LOG']).write_text(json.dumps({'argv':sys.argv[1:],'payload':payload,'skip':os.environ.get('CLAUDE_LEARN_SKIP'),'nested':os.environ.get('CLAUDECODE'),'cwd':os.getcwd(),'empty':not list(pathlib.Path.cwd().iterdir())}))
print(json.dumps({'structured_output':{'links':[{'index':0,'target':os.environ['JUDGE_TARGET'],'relation':os.environ['JUDGE_RELATION']}]}}))
STUB
    chmod +x "$SESSION_LEARNINGS_EXTRACTOR"
    printf '%s' '{"lessons":[{"op":"add","scope":"project","kind":"gotcha","trigger":"When verifying package downloads","claim":"Always verify checksums before installing the downloaded package.","evidence_line":1,"proof":"The human confirmed it."}]}' > "$TMP/candidates"
}
teardown() { teardown_tmp; }
dedup() { "$SCRIPTS/sl-dedup.sh" --store="$TMP/store" --project=-example-project < "$TMP/candidates"; }
change_claim() { jq --arg claim "$1" '.lessons[0].claim=$claim' "$TMP/candidates" > "$TMP/change"; mv "$TMP/change" "$TMP/candidates"; }

@test "exact normalized match links deterministically without a judge call" {
    change_claim 'ALWAYS  verify checksums before installing the downloaded package.'
    run dedup
    assert_status 0
    [ "$(jq -r '.links[0].target' <<< "$output")" = "$JUDGE_TARGET" ]
    [ "$(jq -r '.links[0].by' <<< "$output")" = exact ]
    [ ! -e "$JUDGE_LOG" ]
}

@test "high-similarity negation is judged and never auto-confirmed" {
    change_claim 'Never verify checksums before installing the downloaded package.'
    export JUDGE_RELATION=contradicts
    run dedup
    assert_status 0
    [ "$(jq -r '.links[0].relation' <<< "$output")" = contradicts ]
    [ "$(jq -r '.links[0].by' <<< "$output")" = judge ]
    [ "$(jq '.links[0].similarity > 0.6' <<< "$output")" = true ]
    python3 - "$JUDGE_LOG" "$REPO_ROOT" <<'PY'
import json,pathlib,sys
c=json.loads(pathlib.Path(sys.argv[1]).read_text()); r=pathlib.Path(sys.argv[2])/'plugins/session-learnings'
assert c['argv']==['-p','--model','claude-opus-5-5','--safe-mode','--no-session-persistence','--tools','','--output-format','json','--json-schema',(r/'schema/judge.schema.json').read_text(),'--system-prompt',(r/'prompts/judge.md').read_text()]
assert c['skip']=='1' and c['nested'] is None and c['empty']
assert not pathlib.Path(c['cwd']).exists()
assert len(c['payload']['candidates'][0]['options']) <= 5
PY
}

@test "different scope project and archived statuses cannot become exact targets" {
    change_claim 'This draft must never be recalled.'
    jq '.lessons[0].scope="global" | .lessons[0].trigger="When handling draft data"' "$TMP/candidates" > "$TMP/change"
    mv "$TMP/change" "$TMP/candidates"
    run dedup
    assert_status 0
    [ "$(jq '.links | length' <<< "$output")" = 0 ]
    [ ! -e "$JUDGE_LOG" ]
}

@test "judge errors timeouts malformed replies and invented ids degrade to no link" {
    change_claim 'Never verify checksums before installing the downloaded package.'
    stub judge 'exit 9'
    run dedup
    assert_status 0
    assert_contains "$output" '"links": []'
    stub judge 'echo not-json'
    run dedup
    assert_status 0
    assert_contains "$output" '"links": []'
    stub judge 'sleep 3'
    export SESSION_LEARNINGS_TIMEOUT=1
    run dedup
    assert_status 0
    assert_contains "$output" '"links": []'
}

@test "unknown judge target is rejected, and invalid candidates exit 2 before a model call" {
    change_claim 'Never verify checksums before installing the downloaded package.'
    export JUDGE_TARGET="lsn-$(printf '0%.0s' {1..64})"
    run dedup
    assert_status 0
    [ "$(jq '.links | length' <<< "$output")" = 0 ]
    rm "$JUDGE_LOG"
    printf '%s' '{"lessons":[{"claim":"incomplete"}]}' > "$TMP/candidates"
    run dedup
    assert_status 2
    [ ! -e "$JUDGE_LOG" ]
}

@test "exact links merge into the existing card through the real ledger" {
    dedup > "$TMP/links"
    printf '%s\n' '{"line":1,"class":"human","text":"The package checksum verified correctly."}' > "$TMP/digest"
    "$SCRIPTS/sl-merge.sh" --store="$TMP/store" --session=third --project=-example-project --digest="$TMP/digest" --links="$TMP/links" < "$TMP/candidates"
    rows="$("$SCRIPTS/sl-ledger.sh" list --store="$TMP/store")"
    [ "$(jq -s 'length' <<< "$rows")" = 7 ]
    [ "$(jq 'select(.claim|startswith("Always")) | .counts.sessions' <<< "$rows")" = 3 ]
}
