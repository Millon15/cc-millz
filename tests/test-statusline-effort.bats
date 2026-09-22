#!/usr/bin/env bats
# The effort label in the model segment: the live session level Claude Code
# sends on stdin wins, settings.json is the fallback for builds that send none.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    SCRIPT="${REPO_ROOT}/plugins/statusline/scripts/statusline.sh"
    export HOME="${TMP}/home" TMPDIR="${TMP}" USER="statusline-test"
    mkdir -p "${HOME}/.claude"
    printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_BIN}/security"
    printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_BIN}/curl"
    chmod +x "${STUB_BIN}/security" "${STUB_BIN}/curl"
}

teardown() { teardown_tmp; }

settings_effort() {
    jq -n --arg level "$1" '{effortLevel: $level}' >"${HOME}/.claude/settings.json"
}

render_line1() {
    jq -n --arg cwd "${TMP}" --argjson extra "$1" \
        '{cwd: $cwd, session_id: "effort-test", model: {display_name: "Opus 5.5 (1M context)"}} + $extra' |
        bash "${SCRIPT}" | head -1 | sed $'s/\e\\[[0-9;]*m//g'
}

@test "live effort.level on stdin wins over settings effortLevel" {
    settings_effort high
    run render_line1 '{"effort": {"level": "xhigh"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[Opus 5.5 1M Xhigh]"* ]]
}

@test "settings effortLevel is the fallback when stdin carries no effort" {
    settings_effort high
    run render_line1 '{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[Opus 5.5 1M High]"* ]]
}

@test "no effort anywhere renders no effort label" {
    run render_line1 '{}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[Opus 5.5 1M]"* ]]
}
