#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "shared build: generated commands and Codex skills match canonical protocol" {
    run python3 "$REPO_ROOT/scripts/sync-peer-chat-protocol.py" --check
    [ "$status" -eq 0 ]
}

@test "background build: standalone skill names native lifecycle and does not invoke pane transport" {
    local skill="$REPO_ROOT/plugins/peer-chat-bg/skills/build/SKILL.md"
    run grep -E 'peer-chat-bg:peer-chat|bounded native wait|frozen|incomplete' "$skill"
    [ "$status" -eq 0 ]
    ! grep -qE 'agtermctl|Skill\(skill="peer-chat:peer-chat"\)|other pane' "$skill"
}

@test "background peer: both requested Codex skills are independently packaged" {
    local isolated="$BATS_TEST_TMPDIR/peer-chat-bg"
    cp -R "$REPO_ROOT/plugins/peer-chat-bg" "$isolated"
    [ -f "$isolated/skills/build/SKILL.md" ]
    [ -f "$isolated/skills/peer-chat/SKILL.md" ]
    run bash "$isolated/scripts/peer-chat-bg.sh" --explain
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .plugin)" = peer-chat-bg ]
}
