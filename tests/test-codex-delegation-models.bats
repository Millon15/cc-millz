#!/usr/bin/env bats
#
# tests/test-codex-delegation-models.bats
#
# Codex resolves no family alias: `-m sol` is an HTTP 400, and the openai-codex
# companion maps only `spark`. So the plugins write the family word in prose and
# the full slug wherever a binary reads it, and the codex-delegate rubric is the
# one place that names the slug for delegated work. A transport that drops the
# model silently runs the user's config default instead, so every shipped Codex
# invocation shape must carry it. Markdown bodies have no CLI boundary, so the
# contract is asserted by grepping them.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    DELEGATION="${REPO_ROOT}/plugins/codex-delegation"
    RUBRIC="${DELEGATION}/skills/codex-delegate/SKILL.md"
    WORKER="${DELEGATION}/agents/codex-workflow-worker.md"
    FANOUT="${DELEGATION}/skills/codex-workflow-fanout/SKILL.md"
    COMPUTER_USE="${DELEGATION}/skills/codex-computer-use/SKILL.md"
    REVMUX_PROFILES="${REPO_ROOT}/plugins/revmux-kit/skills/revmux-kit/templates/profiles"
    RALPHEX_SNIPPET="${REPO_ROOT}/plugins/ralphex-revmux/skills/ralphex-revmux/templates/ralphex-config.snippet"
}

rubric_slug() {
    grep -oE "Today's \`sol\` is \`gpt-[0-9][0-9.]*-sol\`" "${RUBRIC}" | grep -oE 'gpt-[0-9][0-9.]*-sol'
}

@test "codex-delegation: the rubric names exactly one sol slug" {
    run rubric_slug
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "codex-delegation: every codex exec shape passes the model" {
    run grep -h 'codex exec -C' "${WORKER}" "${FANOUT}" "${COMPUTER_USE}"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    for line in "${lines[@]}"; do
        [[ "$line" == *" -m <m> "* ]] || { echo "no -m: $line" >&2; return 1; }
    done
}

@test "codex-delegation: both fallbacks pass the effort through codex config" {
    run grep -h 'codex exec -C <repo> -s workspace-write' "${WORKER}" "${FANOUT}"
    [ "${#lines[@]}" -eq 2 ]
    for line in "${lines[@]}"; do
        [[ "$line" == *"-c model_reasoning_effort=<e>"* ]] || { echo "no effort: $line" >&2; return 1; }
    done
}

@test "codex-delegation: the companion task shape requires --model" {
    run grep -h 'task \[--write\]' "${WORKER}" "${FANOUT}"
    [ "${#lines[@]}" -eq 2 ]
    for line in "${lines[@]}"; do
        [[ "$line" == *" --model <m> "* && "$line" != *"[--model"* ]] || { echo "optional model: $line" >&2; return 1; }
    done
}

@test "codex-delegation: only the rubric names a gpt slug" {
    run grep -rlE 'gpt-[0-9]+([.][0-9]+)?-[a-z]' "${DELEGATION}" --include='*.md'
    [ "$output" = "${RUBRIC}" ]
}

@test "revmux-kit and ralphex-revmux: runnable pins match the rubric's sol slug" {
    local slug
    slug="$(rubric_slug)"
    grep -q "^model: codex/${slug}:xhigh$" "${REVMUX_PROFILES}/sol-panel.md"
    grep -q "^model: codex/${slug}:xhigh$" "${REVMUX_PROFILES}/sol-final.md"
    grep -q "^codex_model = ${slug}$" "${RALPHEX_SNIPPET}"
}

@test "codex plugins: no retired gpt-5 slug remains" {
    run grep -rnE 'gpt-5\.(5|6)' "${REPO_ROOT}/plugins/codex-delegation" "${REPO_ROOT}/plugins/revmux-kit" \
        "${REPO_ROOT}/plugins/ralphex-revmux"
    [ "$status" -eq 1 ]
}
