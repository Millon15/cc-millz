#!/usr/bin/env bats
#
# tests/test-peer-chat-spawn.bats
#
# peer-chat-spawn.sh drives agterm through agtermctl, so the suite stubs agtermctl with a small
# state machine: `tree --json` prints whichever fixture the state file names, `session split on`
# moves the state to a bare split shell, `session type` records what was typed and moves it to
# "codex running". Every call is logged, so the assertions read the exact commands issued and, more
# importantly, the ones NOT issued: a pane that already runs codex gets no keystrokes.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    SPAWN="${PLUGIN}/scripts/peer-chat-spawn.sh"
    FIX="${REPO_ROOT}/tests/fixtures/peer-chat"
    SID="11111111-1111-1111-1111-111111111111"
    export AGTERM_ENABLED=1 AGTERM_SESSION_ID="${SID}" AGTERM_PANE=left
    export PEER_CHAT_START_TIMEOUT=2
    unset PEER_CHAT_CODEX_ARGS PEER_CHAT_CODEX_COMMAND PEER_CHAT_CLAUDE_COMMAND
    stub codex
    stub peer-chat.py
    stub_agtermctl
    cd "${TMP}"
}

teardown() { teardown_tmp; }

# set_tree <fixture-basename> — what the stub's `tree --json` prints until an action moves it.
set_tree() { printf '%s' "$1" > "${TMP}/tree-state"; }

stub_agtermctl() {
    cat > "${STUB_BIN}/agtermctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TMP}/calls.log"
state="\$(cat "${TMP}/tree-state")"
case "\$1 \$2" in
    "tree --json") cat "${FIX}/\${state}.json" ;;
    "session split") printf 'tree-split-shell' > "${TMP}/tree-state"; echo ok ;;
    "session text") echo '%' ;;
    "session type") typed="\$(cat)"; printf '%s\n' "\$typed" >> "${TMP}/typed.log"
        case "\$typed" in /quit*) printf 'tree-split-shell' > "${TMP}/tree-state" ;; *) printf 'tree-split-codex' > "${TMP}/tree-state" ;; esac; echo ok ;;
    "session focus") echo ok ;;
    *) echo "stub: unexpected \$*" >&2; exit 9 ;;
esac
EOF
    chmod +x "${STUB_BIN}/agtermctl"
}

# ------------------------------------------------------------- the package --

@test "peer-chat: manifest is 0.4.0 and the marketplace lists the plugin" {
    run jq -r '.name, .version' "${PLUGIN}/.claude-plugin/plugin.json"
    assert_status 0
    assert_contains "${output}" "peer-chat"
    assert_contains "${output}" "0.4.0"
    run jq -r '.plugins[] | select(.name == "peer-chat") | .source' "${REPO_ROOT}/.claude-plugin/marketplace.json"
    assert_status 0
    assert_contains "${output}" "./plugins/peer-chat"
}

@test "peer-chat: the vendored transport is byte-identical to the pinned upstream hash record" {
    [ -x "${PLUGIN}/scripts/peer-chat.py" ]
    run grep -c 'umputun/agterm/tree/[0-9a-f]\{40\}/cookbook/two-agent-chat' "${PLUGIN}/UPSTREAM.md"
    assert_status 0
    [ "${output}" = "1" ]
}

# ------------------------------------------------------------------ spawn --

@test "spawn: no split — opens one, types the launch line with the session id injected, reports started" {
    set_tree tree-no-split
    run bash "${SPAWN}"
    assert_status 0
    assert_contains "${output}" '"state":"started"'
    assert_contains "$(cat "${TMP}/calls.log")" "session split on --target ${SID}"
    assert_contains "$(cat "${TMP}/calls.log")" "session type --stdin --pane right --target ${SID}"
    assert_contains "$(cat "${TMP}/typed.log")" "codex -c 'shell_environment_policy.set.AGTERM_SESSION_ID=\"${SID}\"'"
    assert_contains "$(cat "${TMP}/calls.log")" "session focus left --target ${SID}"
}

@test "spawn: a visible split at a shell prompt gets the launch line and no second split" {
    set_tree tree-split-shell
    run bash "${SPAWN}"
    assert_status 0
    assert_contains "${output}" '"state":"started"'
    assert_not_contains "$(cat "${TMP}/calls.log")" "session split on"
    assert_contains "$(cat "${TMP}/calls.log")" "session type --stdin --pane right"
}

@test "spawn: codex already in the right pane — nothing is typed, reports already" {
    set_tree tree-split-codex
    run bash "${SPAWN}"
    assert_status 0
    assert_contains "${output}" '"state":"already"'
    [ ! -f "${TMP}/typed.log" ]
    assert_not_contains "$(cat "${TMP}/calls.log")" "session type"
}

@test "spawn: a right pane busy with another program is refused with exit 1 and nothing typed" {
    set_tree tree-split-busy
    run bash "${SPAWN}"
    assert_status 1
    assert_contains "${output}" "busy"
    [ ! -f "${TMP}/typed.log" ]
}

@test "spawn: PEER_CHAT_CODEX_ARGS rides the launch line after the session-id flag" {
    set_tree tree-no-split
    PEER_CHAT_CODEX_ARGS='--profile review' run bash "${SPAWN}"
    assert_status 0
    assert_contains "$(cat "${TMP}/typed.log")" "AGTERM_SESSION_ID=\"${SID}\"' --profile review"
}

@test "spawn: exit 4 when claude is not this session's main-pane foreground" {
    set_tree tree-right-pane-claude
    run bash "${SPAWN}"
    assert_status 4
    assert_contains "${output}" "not 'claude'"
    [ ! -f "${TMP}/typed.log" ]
}

@test "spawn: exit 4 from a right pane, before any agterm read" {
    set_tree tree-no-split
    AGTERM_PANE=right run bash "${SPAWN}"
    assert_status 4
    assert_contains "${output}" "main (left) pane"
    [ ! -f "${TMP}/calls.log" ]
}

@test "spawn: exit 4 outside agterm" {
    set_tree tree-no-split
    AGTERM_ENABLED= run bash "${SPAWN}"
    assert_status 4
    assert_contains "${output}" "not inside agterm"
}

@test "spawn: exit 3 names the missing tool when peer-chat.py is not on PATH" {
    set_tree tree-no-split
    unstub peer-chat.py
    # a real ~/.local/bin/peer-chat.py from peer-chat-install.sh must not satisfy the probe
    PATH="${STUB_BIN}:$(dirname "$(command -v jq)"):/usr/bin:/bin" run bash "${SPAWN}"
    assert_status 3
    assert_contains "${output}" "peer-chat.py not on PATH"
    assert_contains "${output}" "peer-chat-install.sh"
}

@test "spawn: exit 1 with a read-back hint when codex never appears" {
    set_tree tree-split-shell
    # a `session type` that leaves the tree unchanged
    sed -i.bak 's#\*) printf .tree-split-codex. > "[^"]*" ;;#*) : ;;#' "${STUB_BIN}/agtermctl"
    PEER_CHAT_START_TIMEOUT=1 run bash "${SPAWN}"
    assert_status 1
    assert_contains "${output}" "did not appear"
    assert_contains "${output}" "agtermctl session text --pane right --target ${SID}"
}

# ---------------------------------------------------------------- restart --

@test "restart: codex in the right pane gets /quit, then the launch line, reports restarted" {
    set_tree tree-split-codex
    run bash "${SPAWN}" --restart
    assert_status 0
    assert_contains "${output}" '"state":"restarted"'
    typed="$(cat "${TMP}/typed.log")"
    [ "$(printf '%s' "${typed}" | head -1)" = "/quit" ]
    assert_contains "$(printf '%s' "${typed}" | tail -1)" "codex -c 'shell_environment_policy.set.AGTERM_SESSION_ID=\"${SID}\"'"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session split on"
}

@test "restart: with no codex running it behaves like a plain spawn and types no /quit" {
    set_tree tree-no-split
    run bash "${SPAWN}" --restart
    assert_status 0
    assert_contains "${output}" '"state":"started"'
    assert_not_contains "$(cat "${TMP}/typed.log")" "/quit"
}

@test "restart: exit 1 with a read-back hint when codex ignores /quit" {
    set_tree tree-split-codex
    sed -i.bak 's#/quit\*) printf .tree-split-shell. > "[^"]*" ;;#/quit*) : ;;#' "${STUB_BIN}/agtermctl"
    PEER_CHAT_START_TIMEOUT=1 run bash "${SPAWN}" --restart
    assert_status 1
    assert_contains "${output}" "still the right pane's foreground"
}

# ---------------------------------------------------------------- explain --

@test "explain: defaults carry the default source and every value has a source" {
    unset PEER_CHAT_START_TIMEOUT
    run bash "${SPAWN}" --explain
    assert_status 0
    assert_explain_complete "${output}"
    assert_explain_source "${output}" codex_command default
    assert_explain_source "${output}" codex_args default
    assert_explain_source "${output}" claude_command default
    [ "$(printf '%s' "${output}" | jq -r '.values.codex_command')" = "codex" ]
    [ "$(printf '%s' "${output}" | jq -r '.values.start_timeout')" = "30" ]
    [ "$(printf '%s' "${output}" | jq -r '.profile_file')" = "null" ]
}

@test "explain: a committed .peer-chat.json is the profile source, env beats it" {
    make_git_repo "${TMP}/repo"
    printf '{"codex_args":"--profile review","start_timeout":45}\n' > "${TMP}/repo/.peer-chat.json"
    cd "${TMP}/repo"
    unset PEER_CHAT_START_TIMEOUT
    run bash "${SPAWN}" --explain
    assert_status 0
    assert_explain_source "${output}" codex_args profile
    assert_explain_source "${output}" start_timeout profile
    [ "$(printf '%s' "${output}" | jq -r '.values.start_timeout')" = "45" ]
    assert_contains "$(printf '%s' "${output}" | jq -r '.profile_file')" ".peer-chat.json"
    PEER_CHAT_CODEX_ARGS='--yolo' run bash "${SPAWN}" --explain
    assert_status 0
    assert_explain_source "${output}" codex_args "detected:env:PEER_CHAT_CODEX_ARGS"
    [ "$(printf '%s' "${output}" | jq -r '.values.codex_args')" = "--yolo" ]
}

@test "explain: an unparseable profile exits 2 and names the file" {
    make_git_repo "${TMP}/repo"
    printf 'not json' > "${TMP}/repo/.peer-chat.json"
    cd "${TMP}/repo"
    run bash "${SPAWN}" --explain
    assert_status 2
    assert_contains "${output}" "unparseable"
    assert_contains "${output}" ".peer-chat.json"
}

@test "explain: has no side effects on agterm" {
    set_tree tree-no-split
    run bash "${SPAWN}" --explain
    assert_status 0
    [ ! -f "${TMP}/calls.log" ]
}
