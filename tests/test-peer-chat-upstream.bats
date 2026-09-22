#!/usr/bin/env bats
#
# tests/test-peer-chat-upstream.bats
#
# The engine is vendored verbatim under scripts/vendor/, and so is its upstream unittest suite.
# Running that suite here proves the copy still works on this Python, and the sha256 column of
# UPSTREAM.md proves the bytes are the ones it names: a re-vendor that breaks a check or skips the
# provenance update fails at `make test`, not in a user's pane. The suite loads peer-chat.py by
# sibling path, so it runs from a temp dir holding both files.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    cp "${PLUGIN}/scripts/vendor/peer-chat.py" "${TMP}/peer-chat.py"
    cp "${REPO_ROOT}/tests/fixtures/peer-chat/test_peer_chat.py" "${TMP}/test_peer_chat.py"
}

teardown() { teardown_tmp; }

pinned_sha256() { # pinned_sha256 <local file column>
    awk -F' \\| ' -v file="$1" '$1 == "| " file && $3 == "verbatim" { sub(/ \|$/, "", $4); print $4 }' \
        "${PLUGIN}/UPSTREAM.md"
}

@test "upstream: the vendored unittest suite passes against the vendored engine" {
    cd "${TMP}"
    run python3 test_peer_chat.py
    assert_status 0
    assert_contains "${output}" "OK"
    assert_not_contains "${output}" "FAILED"
}

@test "upstream: the vendored engine matches the sha256 UPSTREAM.md pins" {
    pinned="$(pinned_sha256 scripts/vendor/peer-chat.py)"
    [ -n "${pinned}" ]
    [ "$(shasum -a 256 "${PLUGIN}/scripts/vendor/peer-chat.py" | cut -d' ' -f1)" = "${pinned}" ]
}

@test "upstream: the vendored unittest fixture matches the sha256 UPSTREAM.md pins" {
    pinned="$(pinned_sha256 "tests/fixtures/peer-chat/test_peer_chat.py (repo root)")"
    [ -n "${pinned}" ]
    [ "$(shasum -a 256 "${REPO_ROOT}/tests/fixtures/peer-chat/test_peer_chat.py" | cut -d' ' -f1)" = "${pinned}" ]
}

@test "upstream: the adapter loads the vendored engine from its sibling vendor dir" {
    run python3 -c "import runpy; m = runpy.run_path('${PLUGIN}/scripts/peer-chat.py'); print(m['engine'].__file__)"
    assert_status 0
    [ "${output}" = "${PLUGIN}/scripts/vendor/peer-chat.py" ]
}

@test "upstream: the adapter finds an installed engine copied beside it as peer-chat-engine.py" {
    cp "${PLUGIN}/scripts/peer-chat.py" "${TMP}/adapter.py"
    cp "${PLUGIN}/scripts/vendor/peer-chat.py" "${TMP}/peer-chat-engine.py"
    run python3 -c "import runpy; m = runpy.run_path('${TMP}/adapter.py'); print(m['engine'].__file__)"
    assert_status 0
    [ "${output}" = "$(cd "${TMP}" && pwd -P)/peer-chat-engine.py" ]
}

@test "upstream: the adapter without an engine beside it names the installer" {
    cp "${PLUGIN}/scripts/peer-chat.py" "${TMP}/adapter.py"
    run python3 "${TMP}/adapter.py" --to peer --stdin
    [ "${status}" -ne 0 ]
    assert_contains "${output}" "run peer-chat-install.sh"
}
