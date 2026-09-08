#!/usr/bin/env bats
#
# tests/test-peer-chat-upstream.bats
#
# The transport is vendored verbatim, and so is its upstream unittest suite. Running that suite
# here proves the copy is intact and still works on this Python — a re-vendor that breaks a check
# fails at `make test`, not in a user's pane. The suite loads peer-chat.py by sibling path, so it
# runs from a temp dir holding both files.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    cp "${PLUGIN}/scripts/peer-chat.py" "${TMP}/peer-chat.py"
    cp "${REPO_ROOT}/tests/fixtures/peer-chat/test_peer_chat.py" "${TMP}/test_peer_chat.py"
}

teardown() { teardown_tmp; }

@test "upstream: the vendored unittest suite passes against the vendored transport" {
    cd "${TMP}"
    run python3 test_peer_chat.py
    assert_status 0
    assert_contains "${output}" "OK"
    assert_not_contains "${output}" "FAILED"
}

@test "upstream: the transport parses and exposes the two profiles the spawn relies on" {
    run python3 -c "import runpy; m = runpy.run_path('${TMP}/peer-chat.py'); p = m['PROFILES']; print(p['claude'].pane, p['codex'].pane, p['codex'].command)"
    assert_status 0
    [ "${output}" = "left right codex" ]
}
