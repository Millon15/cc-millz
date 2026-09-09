#!/usr/bin/env bats
#
# tests/test-plan-research.bats
#
# plan-research.sh shells out to `claude -p`, so the suite stubs claude with a script that records
# its argv and prints a canned answer. The assertions read the exact flags passed (every MCP server
# off, the permission mode, the slash command with its slug) and the answer file the run leaves
# under <artifacts_dir>/<slug>/.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="${REPO_ROOT}/plugins/plan"
    SCRIPT="${PLUGIN}/scripts/plan-research.sh"
    export PLAN_BIN_DIR="${TMP}/bin" PLAN_CACHE_DIR="${TMP}/cache/plan"
    unset PLAN_CLAUDE_ARGS PLAN_CLAUDE_COMMAND PLAN_ARTIFACTS_DIR PLAN_RESEARCH_TIMEOUT
    stub claude "printf '%s\n' \"\$*\" > '${TMP}/claude-argv'; echo 'verdict: PROVEN'; echo '## Artifacts'; echo 'tmp/a/x/1-proof.php'"
    make_git_repo "${TMP}/repo"
    cd "${TMP}/repo"
}

teardown() { teardown_tmp; }

# ------------------------------------------------------------- the package --

@test "plan: manifest is 0.1.0 and the marketplace lists the plugin" {
    run jq -r '.name, .version' "${PLUGIN}/.claude-plugin/plugin.json"
    assert_status 0
    assert_contains "${output}" "plan"
    assert_contains "${output}" "0.1.0"
    run jq -r '.plugins[] | select(.name == "plan") | .source' "${REPO_ROOT}/.claude-plugin/marketplace.json"
    assert_status 0
    assert_contains "${output}" "./plugins/plan"
}

@test "plan: command and both agents ship, the command is model-invocable and names both agents by plugin prefix" {
    [ -f "${PLUGIN}/commands/research.md" ]
    [ -f "${PLUGIN}/agents/answer-researcher.md" ]
    [ -f "${PLUGIN}/agents/answer-proover.md" ]
    body="$(cat "${PLUGIN}/commands/research.md")"
    assert_not_contains "${body}" "disable-model-invocation"
    assert_contains "${body}" 'subagent_type="plan:answer-researcher"'
    assert_contains "${body}" 'subagent_type="plan:answer-proover"'
    assert_contains "${body}" "RESEARCH_DONE"
    assert_contains "${body}" "PROOF_DONE"
    assert_contains "${body}" ".plan.json"
    assert_contains "${body}" "## Artifacts"
}

@test "plan: the agents read the profile and write only under the artifacts dir" {
    researcher="$(cat "${PLUGIN}/agents/answer-researcher.md")"
    proover="$(cat "${PLUGIN}/agents/answer-proover.md")"
    assert_contains "${researcher}" "profile_path"
    assert_contains "${researcher}" "skills.researcher"
    assert_contains "${researcher}" "RESEARCH_DONE path=tmp/a/<slug>/research.md"
    assert_contains "${proover}" "skills.proover"
    assert_contains "${proover}" "commands.php_in_container"
    assert_contains "${proover}" "PROOF_DONE path=tmp/a/<slug>/proof.md"
    assert_contains "${proover}" "NEVER stub the thing under"
}

# ----------------------------------------------------------------- run --

@test "run: passes the slash command with a derived slug, every MCP server off, acceptEdits by default" {
    run bash "${SCRIPT}" "Does the double payment check group by bid?"
    assert_status 0
    argv="$(cat "${TMP}/claude-argv")"
    assert_contains "${argv}" "-p --strict-mcp-config --output-format text --permission-mode acceptEdits"
    assert_contains "${argv}" "/plan:research slug=does-the-double-payment-check Does the double payment check group by bid?"
    assert_not_contains "${argv}" "dangerously"
    [ -f "${TMP}/repo/tmp/a/does-the-double-payment-check/answer.md" ]
    assert_contains "$(cat "${TMP}/repo/tmp/a/does-the-double-payment-check/answer.md")" "verdict: PROVEN"
    assert_contains "${output}" "answer: tmp/a/does-the-double-payment-check/answer.md"
}

@test "run: --slug pins the directory and the profile's claude_args replace the default" {
    printf '{"claude_args":"--permission-mode acceptEdits --allowedTools Bash(docker:*)","artifacts_dir":"tmp/proofs"}\n' > .plan.json
    run bash "${SCRIPT}" "is it cached" --slug cache-check
    assert_status 0
    argv="$(cat "${TMP}/claude-argv")"
    assert_contains "${argv}" "--allowedTools Bash(docker:*) /plan:research slug=cache-check is it cached"
    [ -f "${TMP}/repo/tmp/proofs/cache-check/answer.md" ]
}

@test "run: a failing claude exits 1 and names the partial answer" {
    stub claude "echo partial; exit 7"
    run bash "${SCRIPT}" "q" --slug q
    assert_status 1
    assert_contains "${output}" "claude exited 7"
    assert_contains "${output}" "tmp/a/q/answer.md"
}

@test "run: exit 3 names the missing claude, exit 2 on usage" {
    unstub claude
    PATH="${STUB_BIN}:/usr/bin:/bin" run bash "${SCRIPT}" "q"
    assert_status 3
    assert_contains "${output}" "'claude' not on PATH"
    run bash "${SCRIPT}"
    assert_status 2
    run bash "${SCRIPT}" "a" "b"
    assert_status 2
    assert_contains "${output}" "one question only"
}

# ------------------------------------------------------------- explain --

@test "explain: defaults carry the default source and every value has a source" {
    run bash "${SCRIPT}" --explain
    assert_status 0
    assert_explain_complete "${output}"
    assert_explain_source "${output}" claude_command default
    assert_explain_source "${output}" claude_args default
    assert_explain_source "${output}" artifacts_dir default
    assert_explain_source "${output}" timeout default
    [ "$(printf '%s' "${output}" | jq -r '.values.artifacts_dir')" = "tmp/a" ]
    [ "$(printf '%s' "${output}" | jq -r '.profile_file')" = "null" ]
}

@test "explain: a committed .plan.json is the profile source, env beats it" {
    printf '{"artifacts_dir":"tmp/proofs","timeout":600}\n' > .plan.json
    run bash "${SCRIPT}" --explain
    assert_status 0
    assert_explain_source "${output}" artifacts_dir profile
    assert_explain_source "${output}" timeout profile
    assert_contains "$(printf '%s' "${output}" | jq -r '.profile_file')" ".plan.json"
    PLAN_ARTIFACTS_DIR=tmp/x run bash "${SCRIPT}" --explain
    assert_status 0
    assert_explain_source "${output}" artifacts_dir "detected:env:PLAN_ARTIFACTS_DIR"
}

@test "explain: an unparseable profile exits 2 and names the file" {
    printf 'not json' > .plan.json
    run bash "${SCRIPT}" --explain
    assert_status 2
    assert_contains "${output}" "unparseable"
    assert_contains "${output}" ".plan.json"
}

# ------------------------------------------------------------- install --

@test "install: writes a launcher that resolves the newest plugin copy, --check passes, no Codex rule is written" {
    export CODEX_HOME="${TMP}/codex"
    run bash "${SCRIPT}" --check
    assert_status 1
    run bash "${SCRIPT}" --install
    assert_status 0
    [ -x "${TMP}/bin/plan-research.sh" ]
    assert_contains "$(cat "${TMP}/bin/plan-research.sh")" "${TMP}/cache/plan"
    [ ! -f "${TMP}/codex/rules/default.rules" ]
    PATH="${TMP}/bin:${PATH}" run bash "${SCRIPT}" --check
    assert_status 0
    run bash "${SCRIPT}" --install
    assert_contains "${output}" "unchanged ${TMP}/bin/plan-research.sh"
}

@test "install: the launcher exits 3 when no plugin copy is installed, and runs the newest one when two are" {
    bash "${SCRIPT}" --install >/dev/null
    run bash "${TMP}/bin/plan-research.sh" --explain
    assert_status 3
    assert_contains "${output}" "not installed"
    mkdir -p "${TMP}/cache/plan/0.1.0/scripts" "${TMP}/cache/plan/0.2.0/scripts"
    printf '#!/usr/bin/env bash\necho old\n' > "${TMP}/cache/plan/0.1.0/scripts/plan-research.sh"
    printf '#!/usr/bin/env bash\necho new\n' > "${TMP}/cache/plan/0.2.0/scripts/plan-research.sh"
    run bash "${TMP}/bin/plan-research.sh"
    assert_status 0
    [ "${output}" = "new" ]
}
