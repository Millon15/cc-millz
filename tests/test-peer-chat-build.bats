#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    COMMAND="${PLUGIN}/skills/build/SKILL.md"
    body="$(cat "${COMMAND}")"
}

@test "peer-chat build: skill is model-invocable and loads the peer-chat engine" {
    frontmatter="$(sed -n '2,/^---$/p' "${COMMAND}" | sed '/^---$/q')"
    assert_not_contains "${frontmatter}" "disable-model-invocation"
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


@test "peer-chat skill: stale session recovery verifies both panes before an explicit retry" {
    skill="$(cat "${PLUGIN}/skills/peer-chat/SKILL.md")"
    assert_contains "${skill}" '## Recovering a stale session'
    assert_contains "${skill}" 'THIS conversation'
    assert_contains "${skill}" 'Exactly one verified pair'
    assert_contains "${skill}" '--session <verified-session-id>'
    assert_contains "${skill}" 'Retain these explicit'
    assert_contains "${skill}" 'no pair or multiple pairs match'
    assert_not_contains "${skill}" 'If a send refuses because the session cannot be found, stop'
}

@test "peer-chat build: ships as one skill per plugin, no same-named command" {
    for plugin in peer-chat peer-chat-bg; do
        [ ! -e "${REPO_ROOT}/plugins/${plugin}/commands/build.md" ]
        skill="$(cat "${REPO_ROOT}/plugins/${plugin}/skills/build/SKILL.md")"
        assert_contains "${skill}" "argument-hint:"
        assert_not_contains "${skill}" "disable-model-invocation"
    done
}

@test "peer-chat build: fresh context, freeze diff, batched rounds and security review" {
    assert_contains "${body}" "peer-chat-fresh.sh --focus"
    assert_contains "${body}" "peer-chat-freeze.py --slug <slug>"
    assert_contains "${body}" "whole round in ONE message"
    assert_contains "${body}" "At most two rounds per"
    assert_contains "${body}" 'Skill(skill="security-review")'
    bg="$(cat "${REPO_ROOT}/plugins/peer-chat-bg/skills/build/SKILL.md")"
    assert_contains "${bg}" "--since <previous token>"
    assert_not_contains "${bg}" "peer-chat-fresh.sh"
}
