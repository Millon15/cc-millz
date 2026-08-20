#!/usr/bin/env bats
#
# plugins/phpstorm/tests/harness-discovery.bats
#
# Harness self-test, not a test of the plugin. Proves the root runner and CI
# discover a bats suite living under plugins/<name>/tests/, and that a red
# suite there fails the run.
#
# Set HARNESS_SELF_FAIL=1 to make the last case fail on purpose. That is how
# the "a deliberate failure fails the workflow" claim is proven without
# shipping a red test.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers.bash"
    setup_tmp
}

teardown() {
    teardown_tmp
}

@test "harness: the shared helper is reachable from a plugin suite" {
    [ -f "${REPO_ROOT}/tests/helpers.bash" ]
    [ -n "${TMP}" ]
    [ -d "${TMP}" ]
}

@test "harness: stub puts an executable ahead of the real one on PATH" {
    stub git 'echo stubbed-git'
    run git anything
    assert_status 0
    assert_contains "${output}" "stubbed-git"
    unstub git
}

@test "harness: assert_explain_source is available to plugin suites" {
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
