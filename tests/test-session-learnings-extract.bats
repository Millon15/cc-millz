#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    EXTRACT="$REPO_ROOT/plugins/session-learnings/scripts/sl-extract.sh"
    export FIX="$REPO_ROOT/tests/fixtures/session-learnings/candidates"
    export SESSION_LEARNINGS_EXTRACTOR="$STUB_BIN/extractor"
    cat > "$SESSION_LEARNINGS_EXTRACTOR" <<'STUB'
#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['TMP'], 'call.json').write_text(json.dumps({'argv':sys.argv[1:], 'cwd':os.getcwd(), 'empty':not list(pathlib.Path.cwd().iterdir()), 'skip':os.environ.get('CLAUDE_LEARN_SKIP'), 'claudecode':os.environ.get('CLAUDECODE'), 'stdin':sys.stdin.read()}))
print(pathlib.Path(os.environ['FIX'], 'valid.json').read_text())
STUB
    chmod +x "$SESSION_LEARNINGS_EXTRACTOR"
}
teardown() { teardown_tmp; }

@test "extract preserves exact no-tools argv, isolated cwd, skip env and configurable model" {
    export SESSION_LEARNINGS_MODEL=test-model CLAUDECODE=nested
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 0
    [ "$(jq '.lessons | length' <<< "$output")" = 1 ]
    python3 - "$TMP/call.json" "$REPO_ROOT" <<'PY'
import json, pathlib, sys
call=json.loads(pathlib.Path(sys.argv[1]).read_text())
root=pathlib.Path(sys.argv[2])/'plugins/session-learnings'
assert call['argv']==['-p','--model','test-model','--safe-mode','--no-session-persistence','--tools','', '--output-format','json','--json-schema',(root/'schema/candidates.schema.json').read_text(),'--system-prompt',(root/'prompts/extract.md').read_text()]
assert call['empty'] and call['skip']=='1' and call['claudecode'] is None
assert not pathlib.Path(call['cwd']).exists()
PY
}

@test "empty digest skips model and bad model JSON fails closed" {
    touch "$TMP/empty"
    run "$EXTRACT" --digest "$TMP/empty"
    assert_status 0
    [ "$output" = '{"lessons":[]}' ]
    [ ! -f "$TMP/call.json" ]
    stub extractor 'printf "%s" "{broken"'
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 3
    assert_not_contains "$output" '{broken'
}

@test "model schema violations and failure exit never become candidate stdout" {
    stub extractor 'printf '\''{"lessons":[{"claim":"invalid"}]}'\'''
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 3
    stub extractor 'echo private-error >&2; exit 7'
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 3
    assert_not_contains "$output" private-error
}

@test "structured output is unwrapped; missing or error envelopes fail closed" {
    stub extractor 'jq '\''{type:"result",is_error:false,structured_output:.}'\'' "$FIX/valid.json"'
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 0
    [ "$(jq '.lessons | length' <<< "$output")" = 1 ]
    stub extractor 'printf '\''{"type":"result","result":"done","is_error":false}'\'''
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 3
    stub extractor 'jq '\''{is_error:true,structured_output:.}'\'' "$FIX/valid.json"'
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 3
}

@test "executable override is one literal path and is never evaled" {
    export SESSION_LEARNINGS_EXTRACTOR="extractor; touch $TMP/injected"
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 3
    [ ! -e "$TMP/injected" ]
}

@test "extractor scrubs direct digest input before model call" {
    printf '%s\n' '{"line":1,"text":"password=supersecret123"}' > "$TMP/digest"
    run "$EXTRACT" --digest "$TMP/digest"
    assert_status 0
    ! rg -q supersecret123 "$TMP/call.json"
}

@test "extractor timeout fails without exposing child output" {
    stub extractor 'sleep 3; echo secret-result'
    export SESSION_LEARNINGS_TIMEOUT=1
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 3
    assert_not_contains "$output" secret-result
}

@test "schemas passed to claude --json-schema carry no \$schema key; the CLI rejects the draft 2020-12 ref" {
    for schema in candidates judge; do
        jq -e 'has("$schema") | not' "${REPO_ROOT}/plugins/session-learnings/schema/${schema}.schema.json"
    done
}

@test "--prompt swaps the system prompt and --usage records cost and duration from the CLI envelope" {
    printf 'custom prompt\n' > "$TMP/prompt.md"
    stub extractor 'printf "%s\n" "$@" > "$TMP/args"; jq '\''{type:"result",is_error:false,total_cost_usd:0.05,duration_ms:900,structured_output:.}'\'' "$FIX/valid.json"'
    run "$EXTRACT" --digest "$FIX/digest.jsonl" --prompt "$TMP/prompt.md" --usage "$TMP/usage.json"
    assert_status 0
    grep -qx 'custom prompt' "$TMP/args"
    [ "$(jq -c . "$TMP/usage.json")" = '{"total_cost_usd":0.05,"duration_ms":900}' ]
}

@test "the prompt carries the wording rules: observable trigger, action + why + check, skip tool help" {
    local prompt="${REPO_ROOT}/plugins/session-learnings/prompts/extract.md"
    grep -q 'observable situation' "$prompt"
    grep -q 'the action, then why it works, then how to check' "$prompt"
    grep -q "Skip what the tool's help" "$prompt"
}

@test "review loads writing-for-agents before drafting skill content" {
    grep -q 'mattpocock-skills:writing-for-agents' "${REPO_ROOT}/plugins/session-learnings/commands/review.md"
}

@test "without SESSION_LEARNINGS_MODEL the extractor asks for claude-opus-5-5" {
    unset SESSION_LEARNINGS_MODEL
    run "$EXTRACT" --digest "$FIX/digest.jsonl"
    assert_status 0
    [ "$(jq -r '.argv[2]' "$TMP/call.json")" = claude-opus-5-5 ]
}
