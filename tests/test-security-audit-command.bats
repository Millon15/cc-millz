#!/usr/bin/env bats
#
# tests/test-security-audit-command.bats
#
# security-audit ships a markdown command and nothing else — no entry script,
# so there is no CLI boundary to drive. Its contract is therefore asserted by
# grepping the shipped body: the two tool fallbacks must each be named, the
# cross-language vocabulary must survive the extraction, the report directory
# must be configurable, and no origin-project literal may remain.
#
# A static grep is weaker than a run, and it is paired with a captured smoke
# log so the claim has an execution behind it. See the proofs directory.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    PLUGIN="${REPO_ROOT}/plugins/security-audit"
    CMD="${PLUGIN}/commands/audit.md"
    BODY="$(cat "${CMD}")"
}

# ------------------------------------------------------------- the package --

@test "security-audit: the plugin manifest is 0.1.0 with an empty dependencies field" {
    run jq -r '.name, .version, (.dependencies | length)' "${PLUGIN}/.claude-plugin/plugin.json"
    assert_status 0
    assert_contains "${output}" "security-audit"
    assert_contains "${output}" "0.1.0"
    [ "$(jq -r '.dependencies | length' "${PLUGIN}/.claude-plugin/plugin.json")" = "0" ]
}

@test "security-audit: the command is registered in the marketplace catalogue" {
    run jq -r '.plugins[] | select(.name == "security-audit") | .source' "${REPO_ROOT}/.claude-plugin/marketplace.json"
    assert_status 0
    assert_contains "${output}" "./plugins/security-audit"
}

@test "security-audit: the command basename is unique across every plugin" {
    local dupes
    dupes="$(cd "${REPO_ROOT}" && find plugins -path '*/commands/*' -name '*.md' -exec basename {} \; | sort | uniq -d)"
    [ -z "${dupes}" ] || {
        printf 'duplicate command basenames across plugins: %s\n' "${dupes}" >&2
        return 1
    }
}

# ------------------------------------------------------- the tool fallbacks --

@test "security-audit: the Semgrep fallback is named in the body" {
    assert_contains "${BODY}" 'command -v semgrep'
    assert_contains "${BODY}" 'rg` pattern pass'
}

@test "security-audit: the IDE-search fallback is named in the body" {
    assert_contains "${BODY}" 'IDE search surface'
    assert_contains "${BODY}" 'ripgrep'
}

@test "security-audit: a missing tool downgrades evidence rather than skipping a phase" {
    assert_contains "${BODY}" 'A missing tool NEVER skips a phase'
    assert_contains "${BODY}" 'scanner: semgrep'
}

@test "security-audit: no phase hard-requires a tool that may be absent" {
    # The pre-extraction body ordered "Run: `semgrep scan …`" with no branch.
    assert_not_contains "${BODY}" 'Run: `semgrep scan'
    # Nor may the instruments table hard-name one editor's search tool.
    assert_not_contains "${BODY}" 'when the IDE is up'
}

# ------------------------------------------------ the cross-language corpus --

@test "security-audit: the PHP sinks survive beside the other ecosystems" {
    assert_contains "${BODY}" 'curl_exec'
    assert_contains "${BODY}" 'Guzzle'
    assert_contains "${BODY}" 'shell_exec'
    assert_contains "${BODY}" 'unserialize'
}

@test "security-audit: the Node, Python, Go and Rust sinks are all present" {
    assert_contains "${BODY}" 'axios'
    assert_contains "${BODY}" 'pickle'
    assert_contains "${BODY}" 'InsecureSkipVerify'
    assert_contains "${BODY}" 'reqwest'
}

# ------------------------------------------------------------ neutrality -----

@test "security-audit: the report directory is configurable and defaults to system temp" {
    assert_contains "${BODY}" 'SECURITY_AUDIT_REPORT_DIR'
    assert_contains "${BODY}" '${TMPDIR:-/tmp}/security-audits'
    # Nothing is written into the consuming repo by default: the old body hard-coded
    # a repo-relative tmp/ path in both the terminal verdict and the report header.
    assert_not_contains "${BODY}" 'Full report: tmp/security-audits'
    assert_not_contains "${BODY}" 'Save to `tmp/security-audits'
}

@test "security-audit: no house-style reference survives" {
    assert_not_contains "${BODY}" 'house style'
}

@test "security-audit: the command names itself by its plugin invocation" {
    assert_contains "${BODY}" '/security-audit:audit'
    assert_not_contains "${BODY}" '/generate:security-audit'
}

@test "security-audit: no editor-specific MCP tool call is hard-coded" {
    assert_not_contains "${BODY}" 'mcp__'
}
