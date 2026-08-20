#!/usr/bin/env bats
#
# tests/test-harness-discovery.bats
#
# Harness self-test. Proves the root runner and CI discover a bats suite by the
# tests/test-*.bats glob, that the shared helper is reachable from it, and that
# a red suite fails the run.
#
# Set HARNESS_SELF_FAIL=1 to make the last case fail on purpose. That is how
# the "a deliberate failure fails the workflow" claim is proven without
# shipping a red test.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
}

teardown() {
    teardown_tmp
}

@test "harness: the shared helper is reachable from a discovered suite" {
    [ -f "${REPO_ROOT}/tests/helpers/common.bash" ]
    [ -n "${TMP}" ]
    [ -d "${TMP}" ]
}

@test "harness: no TRACKED suite hides under plugins/<name>/tests/" {
    # A plugin install copies that plugin's directory out of the marketplace
    # clone, so a tracked tests dir there ships to every user of the plugin.
    # Tracked is the right scope: only what git carries reaches a clone.
    run bash -c "cd '${REPO_ROOT}' && git ls-files -- 'plugins/*/tests/*'"
    assert_status 0
    [ -z "${output}" ]
}

@test "harness: stub puts an executable ahead of the real one on PATH" {
    stub git 'echo stubbed-git'
    run git anything
    assert_status 0
    assert_contains "${output}" "stubbed-git"
    unstub git
}

@test "harness: assert_explain_source is available to every suite" {
    local json='{"plugin":"harness","profile_file":null,"values":{"k":"v"},"sources":{"k":"default"}}'
    assert_explain_source "${json}" k default
    assert_explain_complete "${json}"
}

@test "harness: a deliberate failure fails the run when asked" {
    if [ "${HARNESS_SELF_FAIL:-0}" = "1" ]; then
        printf 'harness self-check: failing on purpose\n' >&2
        return 1
    fi
    return 0
}
