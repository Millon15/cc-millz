#!/usr/bin/env bats
#
# tests/test-codex-delegation-models.bats
#
# codex-delegation v0.2 leaves the model to Codex's own config unless asked, runs every
# lane through the codex-job adapter, never widens the sandbox and never re-sends a
# launched prompt. Markdown bodies have no CLI boundary, so those contracts are asserted
# by grepping the shipped content. The sol pins that revmux-kit and ralphex-revmux still
# carry must agree with each other, since no rubric names the slug any more.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    DELEGATION="${REPO_ROOT}/plugins/codex-delegation"
    REVMUX_PROFILES="${REPO_ROOT}/plugins/revmux-kit/skills/revmux-kit/templates/profiles"
    RALPHEX_SNIPPET="${REPO_ROOT}/plugins/ralphex-revmux/skills/ralphex-revmux/templates/ralphex-config.snippet"
}

@test "codex-delegation: no shipped markdown names a gpt slug" {
    run grep -rlE 'gpt-[0-9]+([.][0-9]+)?-[a-z]' "${DELEGATION}" --include='*.md'
    [ "$status" -eq 1 ]
}

@test "codex-delegation: no model ratings table" {
    run grep -rniE '\|[[:space:]]*(intelligence|taste)[[:space:]]*\|' "${DELEGATION}" --include='*.md'
    [ "$status" -eq 1 ]
}

@test "codex-delegation: nothing ships danger-full-access" {
    run grep -rn 'danger-full-access' "${DELEGATION}"
    [ "$status" -eq 1 ]
}

@test "codex-delegation: no runnable codex exec shape, so no post-launch replay" {
    run grep -rnE 'codex exec -' "${DELEGATION}"
    [ "$status" -eq 1 ]
    run grep -rniE 'fallback ONCE|fall back once' "${DELEGATION}"
    [ "$status" -eq 1 ]
}

@test "codex-delegation: every lane runs through the codex-job adapter" {
    for body in skills/codex-workflow-fanout/SKILL.md skills/codex-computer-use/SKILL.md \
        skills/codex-delegate/SKILL.md agents/codex-workflow-worker.md; do
        grep -q 'codex-job' "${DELEGATION}/${body}" || { echo "no adapter: ${body}" >&2; return 1; }
    done
}

@test "codex-delegation: the worker returns the handle, never waiting prose" {
    grep -q 'Never end on a promise to wait' "${DELEGATION}/agents/codex-workflow-worker.md"
    grep -q -- '--wait-seconds 150' "${DELEGATION}/agents/codex-workflow-worker.md"
}

@test "codex-delegation: Claude-side only, no Codex manifest or Codex marketplace entry" {
    [ ! -e "${DELEGATION}/.codex-plugin" ]
    run jq -e '.plugins[] | select(.name == "codex-delegation")' "${REPO_ROOT}/.agents/plugins/marketplace.json"
    [ "$status" -ne 0 ]
}

@test "revmux-kit and ralphex-revmux: the sol pins agree" {
    local panel final snippet
    panel="$(sed -n 's/^model: codex\/\(gpt-[0-9][0-9.]*-sol\):xhigh$/\1/p' "${REVMUX_PROFILES}/sol-panel.md")"
    final="$(sed -n 's/^model: codex\/\(gpt-[0-9][0-9.]*-sol\):xhigh$/\1/p' "${REVMUX_PROFILES}/sol-final.md")"
    snippet="$(sed -n 's/^codex_model = \(gpt-[0-9][0-9.]*-sol\)$/\1/p' "${RALPHEX_SNIPPET}")"
    [ -n "${panel}" ]
    [ "${panel}" = "${final}" ]
    [ "${panel}" = "${snippet}" ]
}

@test "codex plugins: no retired gpt-5 slug remains" {
    run grep -rnE 'gpt-5\.(5|6)' "${REPO_ROOT}/plugins/codex-delegation" "${REPO_ROOT}/plugins/revmux-kit" \
        "${REPO_ROOT}/plugins/ralphex-revmux"
    [ "$status" -eq 1 ]
}
