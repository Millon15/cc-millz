#!/usr/bin/env bats
#
# tests/test-helpers.bats — tests for the shared helper every suite uses.
#
# assert_explain_source is the single line each plugin's --explain coverage
# leans on, so its own failure modes are asserted here rather than assumed.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    GOOD='{"plugin":"merge-kit","profile_file":".merge-kit.json","values":{"test_cmd":"npm test","forge":"gh"},"sources":{"test_cmd":"profile","forge":"detected:origin-url"}}'
}

teardown() {
    teardown_tmp
}

@test "assert_explain_source: a matching source passes" {
    run assert_explain_source "${GOOD}" test_cmd profile
    assert_status 0
}

@test "assert_explain_source: a detected: source passes with its signal" {
    run assert_explain_source "${GOOD}" forge detected:origin-url
    assert_status 0
}

@test "assert_explain_source: a mismatched source fails and names both" {
    run assert_explain_source "${GOOD}" forge profile
    assert_status 1
    assert_contains "${output}" "forge source is detected:origin-url, expected profile"
}

@test "assert_explain_source: a key missing from values fails" {
    run assert_explain_source '{"values":{},"sources":{"k":"default"}}' k default
    assert_status 1
    assert_contains "${output}" "missing from values"
}

@test "assert_explain_source: a key missing from sources fails" {
    run assert_explain_source '{"values":{"k":"v"},"sources":{}}' k default
    assert_status 1
    assert_contains "${output}" "missing from sources"
}

@test "assert_explain_source: input that is not JSON fails" {
    run assert_explain_source 'usage: merge-kit.sh --explain' k default
    assert_status 1
    assert_contains "${output}" "not valid JSON"
}

@test "assert_explain_complete: every values key mirrored in sources passes" {
    run assert_explain_complete "${GOOD}"
    assert_status 0
}

@test "assert_explain_complete: a values key with no source fails and names it" {
    run assert_explain_complete '{"values":{"a":1,"b":2},"sources":{"a":"profile"}}'
    assert_status 1
    assert_contains "${output}" "values keys with no source: b"
}

@test "setup_tmp: makes a temp dir and puts a stub dir first on PATH" {
    [ -d "${TMP}" ]
    [ -d "${STUB_BIN}" ]
    case "${PATH}" in "${STUB_BIN}:"*) ;; *) return 1 ;; esac
}

@test "stub: shadows a real executable, unstub restores it" {
    stub jq 'echo shadowed'
    run jq --version
    assert_status 0
    assert_contains "${output}" "shadowed"

    unstub jq
    run jq --version
    assert_status 0
    assert_not_contains "${output}" "shadowed"
}

@test "stub: a bodiless stub just succeeds, which is enough for a probe" {
    stub semgrep
    run command -v semgrep
    assert_status 0
    run semgrep --config auto
    assert_status 0
}

@test "make_git_repo: builds an isolated repo that can commit" {
    make_git_repo "${TMP}/fixture"
    printf 'x\n' >"${TMP}/fixture/f.txt"
    git -C "${TMP}/fixture" add f.txt
    run git -C "${TMP}/fixture" commit -q -m "fixture"
    assert_status 0
    run git -C "${TMP}/fixture" log -1 --format=%an
    assert_contains "${output}" "t"
}
