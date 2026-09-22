#!/usr/bin/env bats
#
# tests/test-marketplace-manifests.bats
#
# Repo-wide manifest invariants, looped over every plugin. Per-plugin suites
# never pin a version: a bump would turn them red without anything breaking.
# Each rule prints the plugins that break it, so a failure names them all.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "${REPO_ROOT}/tests/helpers/common.bash"
    CLAUDE_MARKETPLACE="${REPO_ROOT}/.claude-plugin/marketplace.json"
    CODEX_MARKETPLACE="${REPO_ROOT}/.agents/plugins/marketplace.json"
}

plugin_dirs() {
    find "${REPO_ROOT}/plugins" -mindepth 1 -maxdepth 1 -type d | sort
}

manifest_field() {
    jq -r --arg field "$2" '.[$field] // empty' "$1/.claude-plugin/plugin.json"
}

offenders_of() {
    local rule="$1" dir
    for dir in $(plugin_dirs); do
        "${rule}" "${dir}" || basename "${dir}"
    done
}

assert_no_offenders() {
    run offenders_of "$1"
    assert_status 0
    [ -z "${output}" ] || {
        printf 'rule %s broken by:\n%s\n' "$1" "${output}"
        return 1
    }
}

has_semver_version() {
    [[ "$(manifest_field "$1" version)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

name_matches_directory() {
    [ "$(manifest_field "$1" name)" = "$(basename "$1")" ]
}

codex_manifest_agrees() {
    local codex="$1/.codex-plugin/plugin.json"
    [ -f "${codex}" ] || return 0
    [ "$(jq -r '.name + "@" + .version' "${codex}")" = "$(manifest_field "$1" name)@$(manifest_field "$1" version)" ]
}

listed_in_claude_marketplace() {
    local name
    name="$(basename "$1")"
    jq -e --arg name "${name}" \
        'any(.plugins[]; .name == $name and .source == "./plugins/" + $name)' \
        "${CLAUDE_MARKETPLACE}" >/dev/null
}

listed_in_codex_marketplace() {
    local name
    [ -f "$1/.codex-plugin/plugin.json" ] || return 0
    name="$(basename "$1")"
    jq -e --arg name "${name}" \
        'any(.plugins[]; .name == $name and .source.path == "./plugins/" + $name)' \
        "${CODEX_MARKETPLACE}" >/dev/null
}

changelog_names_version() {
    local name version
    name="$(manifest_field "$1" name)"
    version="$(manifest_field "$1" version)"
    grep -qE "(^|[^a-z-])${name} v?${version//./\\.}([^0-9]|$)" "${REPO_ROOT}/CHANGELOG.md"
}

@test "manifests: every plugin version is semver" {
    assert_no_offenders has_semver_version
}

@test "manifests: every plugin manifest is named after its directory" {
    assert_no_offenders name_matches_directory
}

@test "manifests: a Codex manifest carries the same name and version as the Claude one" {
    assert_no_offenders codex_manifest_agrees
}

@test "marketplace: every plugin is listed in the Claude catalogue at ./plugins/<name>" {
    assert_no_offenders listed_in_claude_marketplace
}

@test "marketplace: every plugin with a Codex manifest is listed in the Codex catalogue" {
    assert_no_offenders listed_in_codex_marketplace
}

@test "changelog: every plugin's current version is named in CHANGELOG.md" {
    assert_no_offenders changelog_names_version
}

@test "marketplace: every ./plugins source in either catalogue exists on disk" {
    run jq -r '.plugins[] | (.source | if type == "string" then . else .path // empty end)
        | select(startswith("./plugins/"))' "${CLAUDE_MARKETPLACE}" "${CODEX_MARKETPLACE}"
    assert_status 0
    local source missing=""
    for source in ${output}; do
        [ -d "${REPO_ROOT}/${source}" ] || missing="${missing} ${source}"
    done
    [ -z "${missing}" ] || {
        printf 'missing plugin dirs:%s\n' "${missing}"
        return 1
    }
}
