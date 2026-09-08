#!/usr/bin/env bats
# tests/test-unslop-kit-sync.bats — scripts/sync-unslop.sh renders the vendored
# unslop-kit:unslop skill from a pstack SKILL.md: upstream body verbatim, the
# disable-model-invocation flag gone, a provenance line carrying the sha.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp

    KIT="${TMP}/kit"
    mkdir -p "${KIT}/scripts"
    cp "${REPO_ROOT}/plugins/unslop-kit/scripts/sync-unslop.sh" "${KIT}/scripts/"
    SYNC="${KIT}/scripts/sync-unslop.sh"
    TARGET="${KIT}/skills/unslop/SKILL.md"

    PSTACK="${TMP}/pstack-install"
    mkdir -p "${PSTACK}/skills/unslop"
    SOURCE="${PSTACK}/skills/unslop/SKILL.md"
    printf -- '---\nname: unslop\ndescription: upstream one-liner\ndisable-model-invocation: true\n---\n\n# Unslop\n\n3. **Rule three.**\n\n---\n\nnot a frontmatter fence\n' >"${SOURCE}"

    export CLAUDE_CONFIG_DIR="${TMP}/config"
    mkdir -p "${CLAUDE_CONFIG_DIR}/plugins"
    printf '{"plugins":{"pstack@cc-millz":[{"installPath":"%s","gitCommitSha":"0123456789abcdef0123"}]}}\n' "${PSTACK}" \
        >"${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json"
}

teardown() { teardown_tmp; }

@test "renders the vendored skill from installed_plugins.json" {
    run bash "${SYNC}"
    assert_status 0
    [ -f "${TARGET}" ]
    assert_contains "$(cat "${TARGET}")" 'name: unslop'
    assert_not_contains "$(cat "${TARGET}")" 'disable-model-invocation'
}

@test "keeps the upstream body verbatim, third fence included" {
    bash "${SYNC}"
    expected="$(sed '1,5d' "${SOURCE}")"
    actual="$(sed '1,5d' "${TARGET}")"
    [ "${expected}" = "${actual}" ]
}

@test "the provenance line carries the short upstream sha" {
    bash "${SYNC}"
    assert_contains "$(sed -n '5p' "${TARGET}")" 'vendored from cursor/plugins pstack/skills/unslop/SKILL.md @ 0123456789ab'
}

@test "--check exits 0 in sync and 1 on drift" {
    bash "${SYNC}"
    run bash "${SYNC}" --check
    assert_status 0
    printf '4. **Rule four.**\n' >>"${SOURCE}"
    run bash "${SYNC}" --check
    assert_status 1
    assert_contains "${output}" 'is behind'
}

@test "an explicit source path wins over installed_plugins.json" {
    other="${TMP}/other.md"
    printf -- '---\nname: unslop\n---\n# Other\n' >"${other}"
    bash "${SYNC}" "${other}"
    assert_contains "$(cat "${TARGET}")" '# Other'
}

@test "exit 2 when pstack is not installed and no path is given" {
    printf '{"plugins":{}}\n' >"${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json"
    run bash "${SYNC}"
    assert_status 2
    assert_contains "${output}" 'pstack@cc-millz is not in'
}
