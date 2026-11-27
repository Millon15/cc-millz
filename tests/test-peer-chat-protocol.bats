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
sys.modules[spec.name] = paste
spec.loader.exec_module(paste)
paste.require_reconciled(state.Store(pathlib.Path(sys.argv[2])), 'left', '')
PY
}

gate_fixture() {
    COORD="${BATS_TEST_TMPDIR}/coordinator"
    OTHER="${BATS_TEST_TMPDIR}/component"
    STATE="${COORD}/tmp/topic/state.json"
    SPEC="${COORD}/tmp/topic/spec.json"
    CLI="${REPO_ROOT}/plugins/peer-chat/scripts/peer-chat-state.py"
    python3 - "${REPO_ROOT}/plugins/peer-chat/scripts" "${COORD}" "${OTHER}" "${1:-}" <<'PY'
from datetime import timedelta
import json, pathlib, subprocess, sys
sys.path.insert(0, sys.argv[1])
import peer_chat_state as p
from peer_chat_core import now_utc
coord, other = map(pathlib.Path, sys.argv[2:4])
for repo in (coord, other):
    repo.mkdir()
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    (repo / '.gitignore').write_text('/tmp/\n')
    (repo / 'code.txt').write_text('original\n')
    subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(repo), '-c', 'user.name=T', '-c', 'user.email=t@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
path = coord / 'tmp/topic/state.json'
store = p.open_topic(path, transport='agterm', slug='topic', host='agterm', repo=coord)
proof = path.parent / 'proof.out'
proof.write_text('fixture peer report and test receipt\n')
for role in ('left', 'right'):
    p.bind_participant(store, role, {'agent_id': role, 'harness': 'codex'})
for role in ('left', 'right'):
    msg = p.prepare_message(store, sender=role, lines=['🎯 fixture result'], key=role, budgets=None, width=0)
    p.claim_delivery(store, msg['message_id'])
    p.observe(store, msg['message_id'], 'pasted')
    p.observe(store, msg['message_id'], 'submit_sent')
    if sys.argv[4] != 'keystrokes':
        p.observe(store, msg['message_id'], 'acknowledged', evidence=proof, actor=p.peer_of(role))
if sys.argv[4] == 'stopped':
    moment = now_utc()
    budgets = p.resolve_budgets('agterm', True, flags={'deadline': '1m', 'grace': '1m', 'wake': '10s'}, estimates={}, env={}, profile={})
    msg = p.prepare_message(store, sender='left', lines=['🔎 fixture', '❓ result?'], key='timed', budgets=budgets, width=0)
    p.claim_delivery(store, msg['message_id'])
    p.observe(store, msg['message_id'], 'pasted')
    p.observe(store, msg['message_id'], 'submit_sent', now=moment - timedelta(minutes=5))
    p.observe(store, msg['message_id'], 'acknowledged', evidence=proof, actor='right')
    token = p.due(store, now=moment - timedelta(minutes=3))[0]['token']
    p.begin(store, token, 'nudge', now=moment - timedelta(minutes=3))
    p.finish(store, token, 'nudge', 'ok', now=moment - timedelta(minutes=3))
    p.begin(store, token, 'stop', now=moment - timedelta(minutes=1))
    p.finish(store, token, 'stop', 'ok', now=moment - timedelta(minutes=1))
    p.withdraw(store, 'left-001', actor='left', reason='abandoned fixture ask', evidence=proof)
(path.parent / 'spec.json').write_text(json.dumps({'repos': [{'repo': str(repo), 'checks': ['suite']} for repo in (coord, other)]}))
PY
    COORD="$(cd "${COORD}" && pwd -P)"
    OTHER="$(cd "${OTHER}" && pwd -P)"
    STATE="${COORD}/tmp/topic/state.json"
    SPEC="${COORD}/tmp/topic/spec.json"
    target="$(python3 "${CLI}" --slug topic --state "${STATE}" target --spec "${SPEC}" | jq -r .id)"
    [ "${#target}" = 64 ]
}

gate_checks() {
    for repo in "${COORD}" "${OTHER}"; do
        run python3 "${CLI}" --slug topic --state "${STATE}" check --repo "${repo}" --name suite --state passed --target-set "${target}" --evidence tmp/topic/proof.out
        [ "$status" = 0 ]
    done
}

gate_confirm() {
    run python3 "${CLI}" --slug topic --state "${STATE}" confirm --target-set "${target}" --actor-id "$1" --evidence tmp/topic/proof.out
}

@test "P2 gate: keystroke receipts cannot confirm or finalize" {
    gate_fixture keystrokes
    gate_checks
    gate_confirm left
    [ "$status" = 2 ]
    [[ "$output" == *"keystrokes are not peer evidence"* ]]
    run python3 "${CLI}" --slug topic --state "${STATE}" finalize --target-set "${target}" --actor-id left
    [ "$status" = 2 ]
    [ "$(jq -r .phase "${STATE}")" = active ]
}

@test "P2 gate: checks and both recipient-evidenced confirmations finalize the entire set" {
    gate_fixture
    gate_checks
    gate_confirm left
    [ "$status" = 0 ]
    run python3 "${CLI}" --slug topic --state "${STATE}" finalize --target-set "${target}" --actor-id left
    [ "$status" = 2 ]
    [[ "$output" == *"both peers must confirm"* ]]
    gate_confirm right
    [ "$status" = 0 ]
    run python3 "${CLI}" --slug topic --state "${STATE}" finalize --target-set "${target}" --actor-id left
    [ "$status" = 0 ]
    [ "$(jq -r .phase <<<"${output}")" = finalized ]
}

@test "P2 gate: changing the second repo invalidates the full set and clears both confirmations on recapture" {
    gate_fixture
    gate_checks
    gate_confirm left
    [ "$status" = 0 ]
    printf 'changed\n' > "${OTHER}/code.txt"
    gate_confirm right
    [ "$status" = 2 ]
    [[ "$output" == *"target working tree changed"* ]]
    old="${target}"
    target="$(python3 "${CLI}" --slug topic --state "${STATE}" target --spec "${SPEC}" | jq -r .id)"
    [ "${old}" != "${target}" ]
    [ "$(jq '.confirmations | length' "${STATE}")" = 0 ]
    [ "$(jq -r --arg repo "${OTHER}" '.checks[$repo].suite.state' "${STATE}")" = incomplete ]
}

@test "P2 gate: the required check set belongs to the target identity" {
    gate_fixture
    gate_checks
    gate_confirm left
    [ "$status" = 0 ]
    jq '.repos[0].checks += ["security"]' "${SPEC}" > "${SPEC}.next"
    mv "${SPEC}.next" "${SPEC}"
    next="$(python3 "${CLI}" --slug topic --state "${STATE}" target --spec "${SPEC}" | jq -r .id)"
    [ "${next}" != "${target}" ]
    [ "$(jq '.confirmations | length' "${STATE}")" = 0 ]
    [ "$(jq -r --arg repo "${COORD}" '.checks[$repo].security.state' "${STATE}")" = incomplete ]
}

@test "P2 gate: a rewritten source keeps the stored proof; a changed stored copy prevents finalization" {
    gate_fixture
    gate_checks
    gate_confirm left
    [ "$status" = 0 ]
    gate_confirm right
    [ "$status" = 0 ]
    blob="$(jq -r --arg repo "${COORD}" '.checks[$repo].suite.evidence.path' "${STATE}")"
    [ "$(basename "$(dirname "${blob}")")" = evidence ]
    printf 'different evidence\n' > "${COORD}/tmp/topic/proof.out"
    chmod u+w "${blob}"
    printf 'forged evidence\n' > "${blob}"
    run python3 "${CLI}" --slug topic --state "${STATE}" finalize --target-set "${target}" --actor-id left
    [ "$status" = 2 ]
    [[ "$output" == *"evidence changed or disappeared"* ]]
}

@test "P2 gate: deleting every evidence source still finalizes from the stored copies" {
    gate_fixture
    gate_checks
    gate_confirm left
    [ "$status" = 0 ]
    gate_confirm right
    [ "$status" = 0 ]
    trash_dir="${BATS_TEST_TMPDIR}/moved"
    mkdir -p "${trash_dir}"
    mv "${COORD}/tmp/topic/proof.out" "${trash_dir}/"
    run python3 "${CLI}" --slug topic --state "${STATE}" finalize --target-set "${target}" --actor-id left
    [ "$status" = 0 ]
    [ "$(jq -r .phase "${STATE}")" = finalized ]
}

@test "P2 gate: actual bytes hidden by assume-unchanged still invalidate the set" {
    gate_fixture
    gate_checks
    git -C "${OTHER}" update-index --assume-unchanged code.txt
    printf 'hidden edit\n' > "${OTHER}/code.txt"
    [ -z "$(git -C "${OTHER}" status --porcelain)" ]
    gate_confirm left
    [ "$status" = 2 ]
    [[ "$output" == *"target working tree changed"* ]]
}

@test "P2 gate: withdrawing the ask does not release a stopped peer's scope" {
    gate_fixture stopped
    gate_checks
    gate_confirm left
    [ "$status" = 2 ]
    [[ "$output" == *"stopped peer scopes remain unresolved"* ]]
    run python3 "${CLI}" --slug topic --state "${STATE}" release --ask-id left-001 --evidence tmp/topic/proof.out
    [ "$status" = 0 ]
    gate_confirm left
    [ "$status" = 0 ]
}

@test "P2 gate: an open ask blocks confirmation even when its message is acknowledged" {
    gate_fixture
    gate_checks
    python3 - "${REPO_ROOT}/plugins/peer-chat/scripts" "${STATE}" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import peer_chat_state as p
store = p.Store(pathlib.Path(sys.argv[2]))
msg = p.prepare_message(store, sender='left', lines=['🔎 fixture', '❓ unresolved?'], key='open', budgets=None, width=0)
p.claim_delivery(store, msg['message_id'])
p.observe(store, msg['message_id'], 'pasted')
p.observe(store, msg['message_id'], 'submit_sent')
p.observe(store, msg['message_id'], 'acknowledged', evidence=pathlib.Path('tmp/topic/proof.out'), actor='right')
PY
    gate_confirm left
    [ "$status" = 2 ]
    [[ "$output" == *"open or deferred asks remain"* ]]
}

@test "P2 gate: untracked symlinks and actual modes belong to the snapshot" {
    gate_fixture
    old="${target}"
    chmod +x "${OTHER}/code.txt"
    ln -s code.txt "${OTHER}/shortcut"
    target="$(python3 "${CLI}" --slug topic --state "${STATE}" target --spec "${SPEC}" | jq -r .id)"
    [ "${target}" != "${old}" ]
    [ "$(jq -r --arg repo "${OTHER}" '.target_set.repos[$repo].snapshot.files.shortcut.kind' "${STATE}")" = symlink ]
    jq -e --arg repo "${OTHER}" '.target_set.repos[$repo].snapshot.files["code.txt"].mode == 493' "${STATE}"
}

@test "P2 gate: committing checked edits additions and deletions preserves checks through finalization" {
    gate_fixture
    printf 'checked edit\n' > "${COORD}/code.txt"
    rm "${OTHER}/code.txt"
    printf 'checked addition\n' > "${OTHER}/new.txt"
    target="$(python3 "${CLI}" --slug topic --state "${STATE}" target --spec "${SPEC}" | jq -r .id)"
    gate_checks
    for repo in "${COORD}" "${OTHER}"; do
        git -C "${repo}" add -A
        git -C "${repo}" -c user.name=T -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm 'commit the checked files'
    done
    gate_confirm left
    [ "$status" = 0 ]
    gate_confirm right
    [ "$status" = 0 ]
    run python3 "${CLI}" --slug topic --state "${STATE}" finalize --target-set "${target}" --actor-id left
    [ "$status" = 0 ]
    [ "$(jq -r .phase <<<"${output}")" = finalized ]
}

scope_spec() {
    jq --argjson paths "$1" '.repos |= map(if (.repo | endswith("/component")) then . + {paths: $paths} else . end)' "${SPEC}" > "${SPEC}.next"
    mv "${SPEC}.next" "${SPEC}"
}

capture() {
    run python3 "${CLI}" --slug topic --state "${STATE}" target --spec "${SPEC}"
}

@test "P2 gate: a scoped target finalizes beside a tracked file nobody can read" {
    gate_fixture
    printf 'SECRET=1\n' > "${OTHER}/secret.env"
    git -C "${OTHER}" add secret.env
    git -C "${OTHER}" -c user.name=T -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm 'tracked secret'
    chmod 000 "${OTHER}/secret.env"
    scope_spec '["code.txt"]'
    capture
    [ "$status" = 0 ]
    target="$(jq -r .id <<<"${output}")"
    jq -e --arg repo "${OTHER}" '.target_set.repos[$repo] | .paths == ["code.txt"] and (.snapshot.files | keys) == ["code.txt"]' "${STATE}"
    gate_checks
    gate_confirm left
    [ "$status" = 0 ]
    gate_confirm right
    [ "$status" = 0 ]
    run python3 "${CLI}" --slug topic --state "${STATE}" finalize --target-set "${target}" --actor-id left
    chmod 600 "${OTHER}/secret.env"
    [ "$status" = 0 ]
    [ "$(jq -r .phase <<<"${output}")" = finalized ]
}

@test "P2 gate: a scoped target sees edits inside its paths and ignores edits outside them" {
    gate_fixture
    printf 'lane\n' > "${OTHER}/lane.txt"
    mkdir -p "${OTHER}/src" && printf 'deep\n' > "${OTHER}/src/deep.txt"
    scope_spec '["src", "code.txt"]'
    capture
    target="$(jq -r .id <<<"${output}")"
    jq -e --arg repo "${OTHER}" '(.target_set.repos[$repo].snapshot.files | keys) == ["code.txt", "src/deep.txt"]' "${STATE}"
    gate_checks
    printf 'outside edit\n' > "${OTHER}/lane.txt"
    gate_confirm left
    [ "$status" = 0 ]
    printf 'inside edit\n' > "${OTHER}/src/deep.txt"
    gate_confirm right
    [ "$status" = 2 ]
    [[ "$output" == *"target working tree changed"* ]]
}

@test "P2 gate: the paths belong to the target identity" {
    gate_fixture
    whole="${target}"
    scope_spec '["code.txt"]'
    capture
    [ "$(jq -r .id <<<"${output}")" != "${whole}" ]
    scoped="$(jq -r .id <<<"${output}")"
    scope_spec '["code.txt", ".gitignore"]'
    capture
    [ "$(jq -r .id <<<"${output}")" != "${scoped}" ]
}

@test "P2 gate: scope paths must be unique, relative and inside the repo" {
    gate_fixture
    for bad in '[]' '["/etc/passwd"]' '["../outside"]' '["src/../../x"]' '["code.txt", "code.txt"]' '[""]' '[7]'; do
        scope_spec "${bad}"
        capture
        [ "$status" = 2 ]
        [[ "$output" == *"paths"* ]]
    done
}

@test "P2 gate: a scoped file reached through a symlinked parent is refused" {
    gate_fixture
    mkdir -p "${OTHER}/src" "${BATS_TEST_TMPDIR}/outside"
    printf 'lane\n' > "${OTHER}/src/code.txt"
    git -C "${OTHER}" add src/code.txt
    git -C "${OTHER}" -c user.name=T -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm 'scoped file'
    scope_spec '["src/code.txt"]'
    capture
    [ "$status" = 0 ]
    target="$(jq -r .id <<<"${output}")"
    gate_checks
    cp "${OTHER}/src/code.txt" "${BATS_TEST_TMPDIR}/outside/code.txt"
    mv "${OTHER}/src" "${BATS_TEST_TMPDIR}/real-src"
    ln -s "${BATS_TEST_TMPDIR}/outside" "${OTHER}/src"
    gate_confirm left
    [ "$status" = 2 ]
    [[ "$output" == *"scoped file src/code.txt resolves through a symlinked directory"* ]]
}
