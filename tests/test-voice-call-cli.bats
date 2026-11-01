#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ENTRY="$ROOT/plugins/voice-call/scripts/voice-call"
    source "$ROOT/tests/helpers/common.bash"
    setup_tmp
    export VOICE_CALL_STATE_DIR="$TMP/state"
    cd "$TMP"
}

teardown() { teardown_tmp; }

@test "voice-call explain has no side effects and reports sources" {
    run "$ENTRY" --explain
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .values.backend)" = auto ]
    assert_explain_source "$output" backend default
    assert_explain_source "$output" model default
    [ "$(printf '%s' "$output" | jq '.values | keys')" = "$(printf '%s' "$output" | jq '.sources | keys')" ]
    [ ! -e "$VOICE_CALL_STATE_DIR" ]
}

@test "voice-call explain reads project profile from nested directory" {
    mkdir .git nested
    printf '%s\n' '{"backend":"realtime","idle_hangup_min":3}' > .voice-call.json
    cd nested
    run "$ENTRY" --explain
    [ "$status" -eq 0 ]
    assert_explain_source "$output" backend profile
    [ "$(printf '%s' "$output" | jq -r .values.model)" = gpt-realtime-2.1 ]
    [ "$(printf '%s' "$output" | jq -r .values.idle_hangup_min)" = 3 ]
}

@test "voice-call rejects malformed or invalid profiles with exit 2" {
    for profile in '{' '[]' '{"backend":"wrong"}' '{"idle_hangup_min":0}' '{"idle_hangup_min":121}' '{"unknown":1}'; do
        printf '%s' "$profile" > .voice-call.json
        run "$ENTRY" --explain
        [ "$status" -eq 2 ]
    done
}

@test "voice-call absent daemon returns exit 3" {
    run "$ENTRY" status --json
    [ "$status" -eq 3 ]
    run "$ENTRY" hangup
    [ "$status" -eq 3 ]
}

@test "voice-call usage errors return exit 2" {
    run "$ENTRY" bind --session test --pane scratch
    [ "$status" -eq 2 ]
    run "$ENTRY" bad-verb
    [ "$status" -eq 2 ]
}

@test "voice-call key check never prints the environment key" {
    export OPENAI_API_KEY=sentinel-do-not-print
    run "$ENTRY" key check
    [ "$status" -eq 0 ]
    [[ "$output" != *sentinel-do-not-print* ]]
}

@test "voice-call entry resolves a symlink" {
    ln -s "$ENTRY" "$TMP/linked-call"
    run "$TMP/linked-call" --explain
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .plugin)" = voice-call ]
}
