#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "shared build: generated build skills match canonical protocol" {
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

@test "background peer: skill names each side's delivery receipt and the closing order" {
    local skill="$REPO_ROOT/plugins/peer-chat-bg/skills/peer-chat/SKILL.md"
    grep -q 'records `dispatching` and never `submitted`' "$skill"
    grep -q 'The parent saves EVERY peer result' "$skill"
    grep -q '"via": "hand-back"' "$skill"
    grep -q 'stale_dispositions' "$skill"
    grep -q 'Exchange the `🏁` closing messages FIRST' "$skill"
}

@test "background peer: model selection inherits or uses an explicit native override" {
    local skill="$REPO_ROOT/plugins/peer-chat-bg/skills/peer-chat/SKILL.md"
    grep -qF 'argument-hint: "[<harness>(<model>)]"' "$skill"
    grep -qF '<harness>(<model>)' "$skill"
    grep -qF '<harness>:<model>' "$skill"
    grep -qF 'No argument, or a bare matching harness: omit `model`' "$skill"
    grep -qF 'call `Agent` without `model`' "$skill"
    grep -qF 'call `spawn_agent` without `model`' "$skill"
    grep -qF 'say the mapping in one line' "$skill"
    grep -qF 'Scripts map nothing.' "$skill"
    grep -qF 'Use isolated context when specifying a Codex model.' "$skill"
}

@test "background peer: cross-runtime requests refuse before state or spawn" {
    local skill="$REPO_ROOT/plugins/peer-chat-bg/skills/peer-chat/SKILL.md"
    grep -qF 'Match the harness to the actual host runtime before creating state or spawning.' "$skill"
    grep -qF 'refuse in one line:' "$skill"
    grep -qF 'use agterm `peer-chat:peer-chat`' "$skill"
    grep -qF 'report the limitation instead of omitting it or substituting another model.' "$skill"
    grep -qF 'Apply its Peer selection rules' "$REPO_ROOT/plugins/peer-chat-bg/skills/build/SKILL.md"
}

@test "shared build: every peer spelling is recognized in both generated inputs" {
    local plugin skill peer
    local pattern='^(claude|codex)(\(.+\)|:.+)?$'
    for plugin in peer-chat peer-chat-bg; do
        skill="$REPO_ROOT/plugins/$plugin/skills/build/SKILL.md"
        grep -qF "$pattern" "$skill"
        grep -qF -- '--peer=<value>' "$skill"
        grep -qF 'when absent, pass no model override' "$skill"
        for peer in claude codex 'codex(astra)' 'claude(fable)' codex:astra claude:fable; do
            [[ "$peer" =~ $pattern ]]
        done
        ! [[ path/to/design.md =~ $pattern ]]
    done
}
