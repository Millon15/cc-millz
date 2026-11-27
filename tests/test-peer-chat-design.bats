#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    PANE="${REPO_ROOT}/plugins/peer-chat/skills"
    BG="${REPO_ROOT}/plugins/peer-chat-bg/skills"
}

@test "design: both generated skills are current and model-invocable" {
    run python3 "${REPO_ROOT}/scripts/sync-peer-chat-protocol.py" --check
    [ "$status" -eq 0 ]
    for skill in "$PANE/design/SKILL.md" "$BG/design/SKILL.md"; do
        grep -qFx 'name: design' "$skill"
        grep -qF 'argument-hint:' "$skill"
        ! grep -qE 'disable-model-invocation|@[A-Z_]+@' "$skill"
    done
}

@test "design: proposal approval binds both peers and the user to immutable bytes" {
    for skill in "$PANE/design/SKILL.md" "$BG/design/SKILL.md"; do
        grep -qF "Quote the user's words verbatim" "$skill"
        grep -qF 'ask the peer for a cold read' "$skill"
        grep -qF 'proposal-vN.md' "$skill"
        grep -qF 'same revision and SHA-256' "$skill"
        grep -qF 'recipient' "$skill"
        grep -qF 'zero open asks' "$skill"
        grep -qF 'obtain both closes and fresh user approval' "$skill"
        grep -qF 'same slug>' "$skill"
    done
}

@test "design: pane handoff preserves the coordinator state through fresh resume" {
    grep -qF 'Skill(skill="peer-chat:peer-chat")' "$PANE/design/SKILL.md"
    grep -qF -- '--state <coordinator state path>' "$PANE/design/SKILL.md"
    grep -qF -- '[--slug <topic>] [--state <path>]' "$PANE/build/SKILL.md"
    grep -qF 'An optional `--state <path>`' "$PANE/build/SKILL.md"
    grep -qF "is omitted, use the initiator's topic state" "$PANE/build/SKILL.md"
    grep -qF 'coordinator state path in the opening message' "$PANE/build/SKILL.md"
    grep -qF 'Carry any explicit `--state <path>` in the resume line' "$PANE/build/SKILL.md"
}

@test "design: only the pane skill opens the commentable review page" {
    grep -qF 'Inside agterm, open it for the user' "$PANE/design/SKILL.md"
    grep -qF 'scripts/peer-chat-review-page.py" --proposal' "$PANE/design/SKILL.md"
    grep -qF 'NN-user-comments-vN.json' "$PANE/design/SKILL.md"
    grep -qF 'Exit 3 means the page closed' "$PANE/design/SKILL.md"
    [ -f "${REPO_ROOT}/plugins/peer-chat/scripts/peer-chat-review-page.html" ]
    ! grep -qF 'review-page' "$BG/design/SKILL.md"
}

@test "design: background handoff reuses its native run and reserved checks" {
    grep -qF 'peer-chat-bg:peer-chat' "$BG/design/SKILL.md"
    grep -qF '/peer-chat-bg:build <absolute proposal path> --slug <same slug>' "$BG/design/SKILL.md"
    grep -qF -- '--check acceptance --check security' "$BG/design/SKILL.md"
    grep -qF '`acceptance` and `security`. Record the acceptance check' "$BG/build/SKILL.md"
    grep -qF 'verify and reuse its coordinator repo, run ID and bound peer' "$BG/build/SKILL.md"
    ! grep -qE 'agtermctl|peer-chat-fresh\.sh|--state <' "$BG/design/SKILL.md" "$BG/build/SKILL.md"
}

@test "design: engines permit the proposal and Build Phase 0 owns the approved snapshot" {
    for skills in "$PANE" "$BG"; do
        grep -qF 'immutable `proposal-vN.md`' "$skills/peer-chat/SKILL.md"
        grep -qF 'verify the approved SHA-256, copy the bytes verbatim' "$skills/build/SKILL.md"
        grep -qF "user's approval in the single \`Source:\` line" "$skills/build/SKILL.md"
    done
}
