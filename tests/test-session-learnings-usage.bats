#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "$REPO_ROOT/tests/helpers/common.bash"
    setup_tmp
    USAGE="$REPO_ROOT/plugins/session-learnings/scripts/sl-usage.sh"
}
teardown() { teardown_tmp; }

@test "usage emits only typed counters, not other private config data" {
    printf '%s' '{"token":"private","skillUsage":{"learned-a":{"usageCount":2,"lastUsedAt":1700000000000},"bad":{"usageCount":true,"lastUsedAt":2},"negative":{"usageCount":-1,"lastUsedAt":2},"extra":{"usageCount":3}}}' > "$TMP/config"
    run "$USAGE" --config="$TMP/config"
    assert_status 0
    [ "$(jq -r '.skill' <<< "$output")" = learned-a ]
    [ "$(jq '.usageCount' <<< "$output")" = 2 ]
    [ "$(jq '.lastUsedAt' <<< "$output")" = 1700000000000 ]
    assert_not_contains "$output" private
}

@test "missing malformed or absent skillUsage yields no output" {
    for content in '{bad' '{}' '{"skillUsage":[]}' '{"skillUsage":null}'; do
        printf '%s' "$content" > "$TMP/config"
        run "$USAGE" --config="$TMP/config"
        assert_status 0
        [ -z "$output" ]
    done
    run "$USAGE" --config="$TMP/missing"
    assert_status 0
    [ -z "$output" ]
}

@test "config directory override selects its .claude.json" {
    export CLAUDE_CONFIG_DIR="$TMP/config-dir"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    printf '%s' '{"skillUsage":{"learned-b":{"usageCount":1,"lastUsedAt":123}}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
    run "$USAGE"
    assert_status 0
    [ "$(jq -r .skill <<< "$output")" = learned-b ]
}
