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

state_fixture() {
    STATE="${BATS_TEST_TMPDIR}/topic/state.json"
    CLI="${REPO_ROOT}/plugins/peer-chat/scripts/peer-chat-state.py"
    python3 - "${REPO_ROOT}/plugins/peer-chat/scripts" "${STATE}" "${1:-}" <<'PY'
from datetime import timedelta
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from peer_chat_core import now_utc
import peer_chat_state as p
path = Path(sys.argv[2])
path.parent.mkdir(parents=True)
store = p.open_topic(path, transport='agterm', slug='topic', host='agterm', repo=path.parent)
for role in ('left', 'right'):
    p.bind_participant(store, role, {'agent_id': role, 'harness': 'codex', 'requested_model': None,
                                   'pane': role, 'session': 'fixture', 'window': 'fixture'})
budgets = p.resolve_budgets('agterm', True, flags={'deadline': '90s', 'grace': '10s', 'wake': '1s'},
                            estimates={}, env={}, profile={})
msg = p.prepare_message(store, sender='left', lines=['🔎 fixture', '❓ current result?'],
                        key='fixture', budgets=budgets, width=0)
p.claim_delivery(store, msg['message_id'])
p.observe(store, msg['message_id'], 'pasted')
if sys.argv[3] == 'uncertain':
    p.observe(store, msg['message_id'], 'uncertain')
else:
    p.observe(store, msg['message_id'], 'submit_sent', now=now_utc() - timedelta(minutes=2))
(path.parent / 'proof.out').write_text('parent checked all handles: settled; peer is idle')
PY
}

@test "state CLI: wake lists an expired budget without writing or sending" {
    state_fixture
    cp "${STATE}" "${BATS_TEST_TMPDIR}/before.json"
    run python3 "${CLI}" --slug topic --state "${STATE}" wake
    [ "$status" = 0 ]
    [ "$(jq -r '.due[0].action' <<<"${output}")" = nudge ]
    [ "$(jq -r '.due[0].token.agent_id' <<<"${output}")" = right ]
    [ "$(jq -r '.wake_in_seconds' <<<"${output}")" = 0 ]
    cmp "${STATE}" "${BATS_TEST_TMPDIR}/before.json"
}

@test "state CLI: intent then finish starts grace once and a stale begin is a no-op" {
    state_fixture
    token="$(python3 "${CLI}" --slug topic --state "${STATE}" wake | jq -c '.due[0].token')"
    run python3 "${CLI}" --slug topic --state "${STATE}" begin --token "${token}" --action nudge
    [ "$status" = 0 ]
    [ "$(jq -r '.action' <<<"${output}")" = nudge ]
    [ "$(python3 "${CLI}" --slug topic --state "${STATE}" wake | jq -c .due)" = '[]' ]
    run python3 "${CLI}" --slug topic --state "${STATE}" finish --token "${token}" --action nudge --outcome ok --detail proof.out
    [ "$status" = 0 ]
    [ "$(jq -r '.phase' <<<"${output}")" = nudged ]
    [ "$(jq -r '.grace_expires_at' <<<"${output}")" != null ]
    expiry="$(jq -r '.grace_expires_at' <<<"${output}")"
    next="$(python3 "${CLI}" --slug topic --state "${STATE}" wake)"
    jq -e --arg expiry "${expiry}" '.next_wake_at <= $expiry and .wake_in_seconds <= 1' <<<"${next}"
    stale="$(jq -c '.timer_gen += 1' <<<"${token}")"
    run python3 "${CLI}" --slug topic --state "${STATE}" begin --token "${stale}" --action stop
    [ "$status" = 0 ]
    [ "$output" = null ]
}

@test "state CLI: a peer receipt rejects the sender and records the real recipient's proof" {
    state_fixture
    mid="$(jq -r '.messages | keys[0]' "${STATE}")"
    run python3 "${CLI}" --slug topic --state "${STATE}" observe --message-id "${mid}" --event acknowledged --actor-id left --evidence proof.out
    [ "$status" = 2 ]
    run python3 "${CLI}" --slug topic --state "${STATE}" observe --message-id "${mid}" --event acknowledged --actor-id right --evidence proof.out
    [ "$status" = 0 ]
    [ "$(jq -r '.state' <<<"${output}")" = acknowledged ]
    [ "$(jq -r '.events[-1].evidence.sha256 | length' <<<"${output}")" = 64 ]
}

@test "state CLI: a missing topic refuses without creating state" {
    run python3 "${REPO_ROOT}/plugins/peer-chat/scripts/peer-chat-state.py" --slug topic --state "${BATS_TEST_TMPDIR}/missing/state.json" status
    [ "$status" = 2 ]
    [ ! -e "${BATS_TEST_TMPDIR}/missing/state.json" ]
}

@test "state CLI: only the asker can withdraw locally with evidence and no new message" {
    state_fixture
    run python3 "${CLI}" --slug topic --state "${STATE}" withdraw --ask-id left-001 --actor-id right --reason abandoned --evidence proof.out
    [ "$status" = 2 ]
    run python3 "${CLI}" --slug topic --state "${STATE}" withdraw --ask-id left-001 --actor-id left --reason 'budget exhausted' --evidence proof.out
    [ "$status" = 0 ]
    [ "$(jq -r '.disposition' <<<"${output}")" = withdrawn ]
    [ "$(jq '.messages | length' "${STATE}")" = 1 ]
    [ "$(jq -r '.timers["left-001"].phase' "${STATE}")" = cleared ]
    [ "$(jq -r '.asks[0].withdrawal.evidence.sha256 | length' "${STATE}")" = 64 ]
    [ "$(python3 "${CLI}" --slug topic --state "${STATE}" wake | jq -r .next_wake_at)" = null ]
}

@test "state CLI: sender transcript evidence reconciles uncertain without another paste" {
    state_fixture uncertain
    mid="$(jq -r '.messages | keys[0]' "${STATE}")"
    run python3 "${CLI}" --slug topic --state "${STATE}" observe --message-id "${mid}" --event submit_sent --actor-id left --evidence proof.out
    [ "$status" = 0 ]
    [ "$(jq -r '.state' <<<"${output}")" = submit_sent ]
    [ "$(jq '.timers | length' "${STATE}")" = 1 ]
    python3 - "${REPO_ROOT}/plugins/peer-chat/scripts" "${STATE}" <<'PY'
import importlib.util, pathlib, sys
sys.path.insert(0, sys.argv[1])
import peer_chat_state as state
spec = importlib.util.spec_from_file_location('paste', pathlib.Path(sys.argv[1]) / 'peer-chat-paste.py')
paste = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paste)
paste.require_reconciled(state.Store(pathlib.Path(sys.argv[2])), 'left', '')
PY
}
