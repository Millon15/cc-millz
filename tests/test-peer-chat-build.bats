#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    COMMAND="${PLUGIN}/commands/build.md"
    body="$(cat "${COMMAND}")"
}

@test "peer-chat build: command requires user invocation and loads the peer-chat engine" {
    frontmatter="$(sed -n '2,/^---$/p' "${COMMAND}" | sed '/^---$/q')"
    assert_contains "${frontmatter}" "disable-model-invocation: true"
    assert_contains "${body}" 'Skill(skill="peer-chat:peer-chat")'
}

@test "peer-chat build: preserves lane context and checks scratch ignore rules" {
    assert_contains "${body}" "## Lanes"
    assert_contains "${body}" "check-ignore"
}

@test "peer-chat build: requires acceptance and names the shared-resource integrator" {
    assert_contains "${body}" "accepted:"
    assert_contains "${body}" "integrator"
}

@test "peer-chat build: distinguishes unproven claims and incomplete checks" {
    assert_contains "${body}" "🎯 unproven:"
    assert_contains "${body}" "incomplete"
}

@test "peer-chat build: engine permits the task-input artifact" {
    skill="$(cat "${PLUGIN}/skills/peer-chat/SKILL.md")"
    assert_contains "${skill}" "task input, the one exception"
    assert_contains "${skill}" '/peer-chat:build'
}
