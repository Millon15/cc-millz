#!/usr/bin/env bats
#
# tests/test-gws-workspace-body.bats
#
# gws-workspace ships one skill and six references and nothing else — no entry
# script, so there is no CLI boundary to drive, and the one binary involved
# belongs to somebody else. Driving it would test Google's CLI, not this
# plugin. The contract is therefore asserted by grepping the shipped bodies:
# the auth ladder must name all three commands, the anchored-comment finding
# must survive verbatim, the safety rules must still be there, scratch files
# must land in the OS temp dir, and no path literal from the origin project
# may remain.
#
# On that last one: this suite asserts the NEUTRAL half — that the traversal
# link, the guide path, the repo-relative scratch dir and any absolute home
# path are absent. It deliberately does NOT enumerate the origin project's
# own names, because a file listing forbidden words in order to search for
# them contains those words, and the neutrality gate reads this file too.
#
# A static grep is weaker than a run, and it is paired with a captured smoke
# log of the real CLI so the claim has an execution behind it. See the proofs
# directory.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    PLUGIN="${REPO_ROOT}/plugins/gws-workspace"
    SKILL_DIR="${PLUGIN}/skills/gws-workspace"
    SKILL="${SKILL_DIR}/SKILL.md"
    BODY="$(cat "${SKILL}")"
    ALL_BODIES="$(cat "${SKILL}" "${SKILL_DIR}"/references/*.md)"
}

# ------------------------------------------------------------- the package --

@test "gws-workspace: the plugin manifest is 0.1.0 with an empty dependencies field" {
    run jq -r '.name, .version' "${PLUGIN}/.claude-plugin/plugin.json"
    assert_status 0
    assert_contains "${output}" "gws-workspace"
    assert_contains "${output}" "0.1.0"
    [ "$(jq -r '.dependencies | length' "${PLUGIN}/.claude-plugin/plugin.json")" = "0" ]
}

@test "gws-workspace: the plugin is registered in the marketplace catalogue" {
    run jq -r '.plugins[] | select(.name == "gws-workspace") | .source' "${REPO_ROOT}/.claude-plugin/marketplace.json"
    assert_status 0
    assert_contains "${output}" "./plugins/gws-workspace"
}

@test "gws-workspace: the plugin ships no command and no script" {
    local commands scripts
    commands="$(find "${PLUGIN}" -path '*/commands/*' -type f)"
    scripts="$(find "${PLUGIN}" \( -path '*/scripts/*' -o -path '*/hooks/*' -o -name '*.sh' \) -type f)"
    [ -z "${commands}" ] || {
        printf 'gws-workspace ships a command, so it claims a basename: %s\n' "${commands}" >&2
        return 1
    }
    [ -z "${scripts}" ] || {
        printf 'gws-workspace ships an executable, so it widens the permission surface: %s\n' "${scripts}" >&2
        return 1
    }
}

@test "gws-workspace: all six references ship beside the skill" {
    local ref
    for ref in gws-docs gws-sheets gws-slides gws-tasks gws-drive gdocs-comments; do
        [ -f "${SKILL_DIR}/references/${ref}.md" ] || {
            printf 'missing reference: %s.md\n' "${ref}" >&2
            return 1
        }
    done
    [ "$(find "${SKILL_DIR}/references" -name '*.md' -type f | wc -l | tr -d ' ')" = "6" ]
}

@test "gws-workspace: every reference the skill links to exists" {
    local target
    while read -r target; do
        [ -z "${target}" ] && continue
        [ -f "${SKILL_DIR}/${target}" ] || {
            printf 'skill links to a missing file: %s\n' "${target}" >&2
            return 1
        }
    done < <(grep -o 'references/[a-z-]*\.md' "${SKILL}" | sort -u)
}

# ------------------------------------------------------------ the auth ladder --

@test "gws-workspace: the prerequisites name all three gws auth commands" {
    assert_contains "${BODY}" 'gws auth setup'
    assert_contains "${BODY}" 'gws auth login'
    assert_contains "${BODY}" 'gws auth status'
}

@test "gws-workspace: setup is described as what login depends on, not as an aside" {
    assert_contains "${BODY}" 'OAuth client'
    assert_contains "${BODY}" 'gcloud'
    # The departing document was the only place first-time setup was written down.
    assert_not_contains "${BODY}" 'For setup details, see'
}

@test "gws-workspace: the README names where the gws CLI comes from" {
    local readme
    readme="$(cat "${PLUGIN}/README.md")"
    assert_contains "${readme}" '@googleworkspace/cli'
    assert_contains "${readme}" 'npm install -g @googleworkspace/cli'
    assert_contains "${readme}" 'github.com/googleworkspace/cli'
}

# ------------------------------------------------------- the load-bearing findings --

@test "gws-workspace: the anchored-comment finding survives verbatim" {
    assert_contains "${BODY}" 'Original content deleted'
    assert_contains "$(cat "${SKILL_DIR}/references/gdocs-comments.md")" 'Original content deleted'
    # And the conclusion drawn from it: the highlighted path is the browser UI.
    assert_contains "${BODY}" 'Docs UI'
}

@test "gws-workspace: the safety section is intact" {
    assert_contains "${BODY}" 'Confirm with user'
    assert_contains "${BODY}" '--dry-run` for destructive operations'
    assert_contains "${BODY}" 'Never output secrets'
}

# --------------------------------------------------------------- neutrality --

@test "gws-workspace: no path literal from the origin project survives" {
    # The one that was there: a relative traversal out of the skill directory
    # into a guide that is not coming along.
    assert_not_contains "${ALL_BODIES}" '../../'
    assert_not_contains "${ALL_BODIES}" 'docs/guides/'
}

@test "gws-workspace: no absolute home path appears in any shipped body" {
    run grep -rnE '/Users/|/home/[a-z]' "${SKILL_DIR}"
    assert_status 1
}

@test "gws-workspace: scratch files land in the OS temp dir, not a repo-relative one" {
    assert_contains "${ALL_BODIES}" '${TMPDIR:-/tmp}'
    run grep -rnE '(^|[^./A-Za-z])tmp/' "${SKILL_DIR}"
    assert_status 1
}
