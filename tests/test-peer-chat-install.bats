#!/usr/bin/env bats
#
# tests/test-peer-chat-install.bats
#
# peer-chat-install.sh writes into three places the two agents read from. The suite points all
# three at a temp HOME through PEER_CHAT_BIN_DIR and CODEX_HOME, so a run never touches the real
# ~/.codex, and asserts idempotence: a second run changes nothing and appends no duplicate rule.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    INSTALL="${PLUGIN}/scripts/peer-chat-install.sh"
    export PEER_CHAT_BIN_DIR="${TMP}/bin" CODEX_HOME="${TMP}/codex"
    PATH="${PEER_CHAT_BIN_DIR}:${PATH}"
    export PATH
}

teardown() { teardown_tmp; }

@test "install: --check on a bare machine exits 1 and names every missing piece" {
    run bash "${INSTALL}" --check
    assert_status 1
    assert_contains "${output}" "MISSING or stale  ${TMP}/bin/peer-chat.py"
    assert_contains "${output}" "MISSING or stale  ${TMP}/bin/peer-chat-paste.py"
    assert_contains "${output}" "MISSING or stale  ${TMP}/codex/skills/peer-chat/SKILL.md"
    assert_contains "${output}" "MISSING  peer-chat rules"
}

@test "install: writes both scripts, the codex skill and the three rules, then --check passes" {
    run bash "${INSTALL}"
    assert_status 0
    [ -x "${TMP}/bin/peer-chat.py" ]
    [ -x "${TMP}/bin/peer-chat-paste.py" ]
    cmp -s "${PLUGIN}/scripts/peer-chat.py" "${TMP}/bin/peer-chat.py"
    cmp -s "${PLUGIN}/scripts/peer-chat-paste.py" "${TMP}/bin/peer-chat-paste.py"
    cmp -s "${PLUGIN}/codex/SKILL.md" "${TMP}/codex/skills/peer-chat/SKILL.md"
    run grep -c 'prefix_rule(pattern=\["peer-chat.py"' "${TMP}/codex/rules/default.rules"
    [ "${output}" = "2" ]
    run grep -c 'prefix_rule(pattern=\["peer-chat-paste.py", "--to", "claude", "--message-file"\]' "${TMP}/codex/rules/default.rules"
    [ "${output}" = "1" ]
    run bash "${INSTALL}" --check
    assert_status 0
}

@test "install: stamps the plugin version, and an older plugin copy never downgrades a newer install" {
    bash "${INSTALL}" >/dev/null
    version="$(jq -r .version "${PLUGIN}/.claude-plugin/plugin.json")"
    [ "$(cat "${TMP}/codex/skills/peer-chat/.version")" = "${version}" ]
    printf '9.9.9\n' > "${TMP}/codex/skills/peer-chat/.version"
    printf '# newer\n' > "${TMP}/codex/skills/peer-chat/SKILL.md"
    run bash "${INSTALL}" --check
    assert_status 0
    assert_contains "${output}" "peer-chat 9.9.9 is installed; this ${version} copy is older and changes nothing"
    run bash "${INSTALL}"
    assert_status 0
    [ "$(cat "${TMP}/codex/skills/peer-chat/SKILL.md")" = "# newer" ]
    [ "$(cat "${TMP}/codex/skills/peer-chat/.version")" = "9.9.9" ]
}

@test "install: a second run is a no-op and never duplicates a rule" {
    bash "${INSTALL}" >/dev/null
    run bash "${INSTALL}"
    assert_status 0
    assert_contains "${output}" "unchanged ${TMP}/bin/peer-chat.py"
    assert_contains "${output}" "present   prefix_rule"
    run grep -c 'peer-chat' "${TMP}/codex/rules/default.rules"
    [ "${output}" = "3" ]
}

@test "install: keeps rules the user already had in default.rules" {
    mkdir -p "${TMP}/codex/rules"
    printf 'prefix_rule(pattern=["git", "status"], decision="allow")\n' > "${TMP}/codex/rules/default.rules"
    bash "${INSTALL}" >/dev/null
    run cat "${TMP}/codex/rules/default.rules"
    assert_contains "${output}" '"git", "status"'
    assert_contains "${output}" '"--prepare-message"'
    assert_contains "${output}" '"--to", "claude", "--message-file"'
}

@test "install: a stale copy of peer-chat.py is refreshed" {
    bash "${INSTALL}" >/dev/null
    printf '# stale\n' > "${TMP}/bin/peer-chat.py"
    run bash "${INSTALL}" --check
    assert_status 1
    run bash "${INSTALL}"
    assert_status 0
    assert_contains "${output}" "wrote     ${TMP}/bin/peer-chat.py"
    cmp -s "${PLUGIN}/scripts/peer-chat.py" "${TMP}/bin/peer-chat.py"
}

@test "install: warns when the bin dir is off PATH" {
    PATH="/usr/bin:/bin" run bash "${INSTALL}"
    assert_status 0
    assert_contains "${output}" "WARN      add ${TMP}/bin to PATH"
}

@test "codex skill: the installed body is the vendored Codex side, with the spawn named" {
    run head -2 "${PLUGIN}/codex/SKILL.md"
    assert_contains "${output}" "name: peer-chat"
    run grep -c 'peer-chat-spawn.sh' "${PLUGIN}/codex/SKILL.md"
    [ "${output}" = "1" ]
}

@test "both skills: carry the message shape with no length cap, the asks ledger, the artifact rule, the proof handshake and the sole-writer exemption" {
    for f in "${PLUGIN}/skills/peer-chat/SKILL.md" "${PLUGIN}/codex/SKILL.md"; do
        body="$(cat "$f")"
        assert_contains "${body}" "## Message shape"
        assert_contains "${body}" "There is no length cap"
        assert_not_contains "${body}" "under 50 characters"
        assert_not_contains "${body}" "under 20 lines"
        assert_not_contains "${body}" "One claim per message"
        assert_contains "${body}" "PEER_CHAT_WRAP"
        assert_contains "${body}" "peer-chat-paste.py"
        assert_contains "${body}" "## Asks"
        assert_contains "${body}" "asks.tsv"
        assert_contains "${body}" "deferred(<what has to happen first>)"
        assert_contains "${body}" "overdue:"
        assert_contains "${body}" "one tool call of your own"
        assert_contains "${body}" "Prose never goes to a file"
        assert_not_contains "${body}" "markdown file only when reasoning"
        assert_contains "${body}" 'tmp/peer-chat/<slug>/'
        assert_contains "${body}" 'NN-<agent>-<what>.<ext>'
        assert_contains "${body}" "## Proofs"
        assert_contains "${body}" "unproven:"
        assert_contains "${body}" "--verify <n>"
        assert_contains "${body}" "fixture not re-run"
        assert_contains "${body}" "I said <X>; <Y> is right because <Z>"
        assert_contains "${body}" 'accepted: "<their words>"; checked'
        assert_contains "${body}" "outside this rule"
        assert_not_contains "${body}" "round n of m staging"
    done
    assert_contains "$(cat "${PLUGIN}/skills/peer-chat/SKILL.md")" "/plan:research"
    assert_contains "$(cat "${PLUGIN}/skills/peer-chat/SKILL.md")" "--to codex --slug <slug> --stdin"
    assert_contains "$(cat "${PLUGIN}/skills/peer-chat/SKILL.md")" "peer-chat-spawn.sh --restart"
    assert_contains "$(cat "${PLUGIN}/codex/SKILL.md")" "plan-research.sh"
    assert_contains "$(cat "${PLUGIN}/codex/SKILL.md")" "--message-file peer-chat-codex-a91f.txt --slug <slug>"
}

@test "claude skill: names the preflight, the spawn, and keeps upstream's guardrails" {
    body="$(cat "${PLUGIN}/skills/peer-chat/SKILL.md")"
    assert_contains "${body}" 'peer-chat-install.sh" --check'
    assert_contains "${body}" 'peer-chat-spawn.sh"'
    assert_contains "${body}" "Never wait for a reply"
    assert_contains "${body}" "sole writer"
    assert_contains "${body}" "Chat from Codex:"
    assert_not_contains "${body}" "never starts an agent"
}

@test "both skills: peers can exchange roles without user reassignment and preserve exclusive ownership" {
    claude_shared="$(sed -n '/^## Shared work$/,/^## Never wait for a reply$/p' "${PLUGIN}/skills/peer-chat/SKILL.md")"
    codex_shared="$(sed -n '/^## Shared work$/,/^## Never wait for a reply$/p' "${PLUGIN}/codex/SKILL.md")"
    [ "${claude_shared}" = "${codex_shared}" ]
    assert_contains "${claude_shared}" "Either agent may ask to exchange roles"
    assert_contains "${claude_shared}" "Do not ask the user to reassign the writer"
    assert_contains "${claude_shared}" "finishes or stops its in-flight edits"
    assert_contains "${claude_shared}" "explicitly releases the writer role"
    assert_contains "${claude_shared}" "explicitly accepts the released role"
    assert_contains "${claude_shared}" "silence, a timeout or a successful send never grants the role"
    assert_contains "${claude_shared}" "last completed handoff persists across turns"
    assert_contains "${claude_shared}" "resolve the roles with the peer"
    assert_contains "${claude_shared}" "unless the user explicitly forbids"
    assert_contains "${claude_shared}" "does not expand the task or supply approval"
    for f in "${PLUGIN}/skills/peer-chat/SKILL.md" "${PLUGIN}/codex/SKILL.md"; do
        body="$(cat "$f")"
        assert_not_contains "${body}" "peer messages never transfer write authority"
        assert_not_contains "${body}" "No peer message revokes, transfers or restores write authority"
        assert_not_contains "${body}" "asks the user to revoke one agent's authority"
        assert_not_contains "${body}" "user must first revoke"
    done
}
