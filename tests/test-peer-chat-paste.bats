#!/usr/bin/env bats
#
# tests/test-peer-chat-paste.bats
#
# peer-chat-paste.py loads the vendored transport as a module and drives agterm through it, so
# the suite stubs agtermctl with a state machine (empty composer, pasted, submitted) and pbcopy /
# pbpaste with a clipboard file. The assertions read what was pasted (the label, the preserved
# line breaks), the single submit keystroke, the clipboard restore, and paste confirmation.
# Composer state never blocks either target, before paste or after submission.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    PASTE="${PEER_CHAT_TEST_PASTE:-${PLUGIN}/scripts/peer-chat-paste.py}"
    FIX="${REPO_ROOT}/tests/fixtures/peer-chat"
    SID="11111111-1111-1111-1111-111111111111"
    export AGTERM_SESSION_ID="${SID}" AGTERM_PANE=left PEER_CHAT_TRANSPORT="${PLUGIN}/scripts/peer-chat.py"
    unset PEER_CHAT_NAME PEER_CHAT_CLAUDE_COMMAND PEER_CHAT_CODEX_COMMAND
    export PEER_CHAT_PASTE_TIMEOUT=1 PEER_CHAT_ACCEPT_TIMEOUT=1
    unset AGTERM_WINDOW_ID
    printf 'user clipboard' > "${TMP}/clip"
    printf 'empty' > "${TMP}/state"
    cp "${FIX}/tree-split-codex.json" "${TMP}/tree.json"
    stub pbcopy "cat > '${TMP}/clip'; grep -q '^Chat from' '${TMP}/clip' || exit 0; cp '${TMP}/clip' '${TMP}/clip-last-set'; [ -f '${TMP}/clip-first-set' ] || cp '${TMP}/clip' '${TMP}/clip-first-set'"
    stub pbpaste "cat '${TMP}/clip'"
    stub_agtermctl
    cd "${TMP}"
}

teardown() { teardown_tmp; }

stub_agtermctl() {
    cat > "${STUB_BIN}/agtermctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TMP}/calls.log"
state="\$(cat "${TMP}/state")"
case "\$1 \$2" in
    "window list") echo '{"result":{"windows":[{"id":"win-1","active":true,"open":true}]}}' ;;
    "tree --json") cat "${TMP}/tree.json" ;;
    "surface cursor") [ ! -f "${TMP}/cursor-unavailable" ] || exit 9; echo 2 ;;
    "session text")
        case "\$state" in
            pasted) cat "${TMP}/clip-last-set"; echo; cat "${TMP}/composer" 2>/dev/null || cat "${FIX}/codex-pane-empty.txt" ;;
            busy) printf '› half a line the user typed\n \n  footer row\n' ;;
            submitted) cat "${TMP}/after-submit" 2>/dev/null || cat "${FIX}/codex-pane-empty.txt" ;;
            *) cat "${TMP}/composer" 2>/dev/null || cat "${FIX}/codex-pane-empty.txt" ;;
        esac ;;
    "session paste")
        [ -f "${TMP}/paste-ignored" ] || printf 'pasted' > "${TMP}/state"
        [ ! -f "${TMP}/composer-after-paste" ] || cp "${TMP}/composer-after-paste" "${TMP}/composer"
        echo ok ;;
    "session type") cat >> "${TMP}/typed.log"; printf 'submitted' > "${TMP}/state"; echo ok ;;
    *) echo "stub: unexpected \$*" >&2; exit 9 ;;
esac
EOF
    chmod +x "${STUB_BIN}/agtermctl"
}

send_file() { # send_file <message-file> [extra args]
    local file="$1"
    shift
    run python3 "${PASTE}" --to peer --stdin "$@" < "${file}"
}

@test "paste: a multi-line body is pasted with the label, submitted once, and the clipboard is restored" {
    printf '🎯 the guard is blind across bids\n\n🔎 DoublePaymentProcessor.php:23-31\n\n❓ does a retry create a second bid?\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" '"lines": 5'
    [ "$(head -1 "${TMP}/clip-first-set")" = "Chat from claude (left): 🎯 the guard is blind across bids" ]
    [ "$(tail -1 "${TMP}/clip-first-set")" = "❓ does a retry create a second bid?" ]
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID}"
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
}

@test "paste: an existing label is not doubled and trailing blank lines are dropped" {
    printf 'Chat from claude (left): 🎯 one line\n\n\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/clip-first-set")" = "Chat from claude (left): 🎯 one line" ]
}

@test "paste: existing draft text does not block paste or submit" {
    printf 'busy' > "${TMP}/state"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_contains "$(cat "${TMP}/calls.log")" "session paste"
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
}

composer_matrix() {
    local target="$1" prompt pane sender state after expected_label
    if [ "$target" = claude ]; then
        prompt='❯'; pane=left; sender=right; expected_label='Chat from codex (right):'
    else
        prompt='›'; pane=right; sender=left; expected_label='Chat from claude (left):'
    fi
    for state in empty suggestion startup_hint ide_context draft multiline queued unknown; do
        case "$state" in
            empty) printf '%s \n' "$prompt" > "${TMP}/composer" ;;
            suggestion) printf '%s keep grilling, dont wait for me\n' "$prompt" > "${TMP}/composer" ;;
            startup_hint) printf '%s Try "fix a bug"\n' "$prompt" > "${TMP}/composer" ;;
            ide_context) printf '%s ⧉ In file.php\n' "$prompt" > "${TMP}/composer" ;;
            draft) printf '%s half a line the user typed\n' "$prompt" > "${TMP}/composer" ;;
            multiline) printf '%s draft line one\n  draft line two\n' "$prompt" > "${TMP}/composer" ;;
            queued) printf '%s Press up to edit queued messages\n' "$prompt" > "${TMP}/composer" ;;
            unknown) printf 'unrecognized composer rendering\n' > "${TMP}/composer" ;;
        esac
        for after in empty occupied; do
            printf 'empty' > "${TMP}/state"
            : > "${TMP}/calls.log"
            : > "${TMP}/typed.log"
            # No cursor probe is needed even if it is unavailable or moved into a draft.
            touch "${TMP}/cursor-unavailable"
            if [ "$after" = empty ]; then
                printf '%s \n' "$prompt" > "${TMP}/after-submit"
            else
                printf '%s another draft or suggestion\n' "$prompt" > "${TMP}/after-submit"
            fi
            printf '🎯 occupancy matrix %s %s %s\n' "$target" "$state" "$after" > "${TMP}/msg"
            AGTERM_PANE="$sender" run python3 "${PASTE}" --to peer --stdin < "${TMP}/msg"
            assert_status 0
            assert_contains "$(cat "${TMP}/clip-last-set")" "$expected_label"
            assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane ${pane} --target ${SID}"
            [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
            [ "$(cat "${TMP}/clip")" = "user clipboard" ]
            assert_not_contains "$(cat "${TMP}/calls.log")" 'surface cursor'
            assert_not_contains "$output" 'composer is not empty'
            assert_not_contains "$output" 'composer did not clear'
            assert_not_contains "$output" 'mid-turn'
        done
    done
}

@test "paste: Claude occupancy matrix never blocks before or after submit" {
    composer_matrix claude
}

@test "paste: Codex occupancy matrix never blocks before or after submit" {
    composer_matrix codex
}

@test "paste: an unconfirmed paste gets no submit key and the clipboard is still restored" {
    touch "${TMP}/paste-ignored"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "paste not confirmed"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
}

@test "paste: a tab becomes a space, CR and other control characters are dropped, the send goes through" {
    printf '🎯 x\ty\r\n\n🔎 a\033[0mb\r\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    [ "$(head -1 "${TMP}/clip-first-set")" = "Chat from claude (left): 🎯 x y" ]
    [ "$(tail -1 "${TMP}/clip-first-set")" = "🔎 a[0mb" ]
    ! grep -q $'\r' "${TMP}/clip-first-set"
}

@test "paste: exit 1 naming peer-chat.py when the transport is not on PATH" {
    unset PEER_CHAT_TRANSPORT
    printf '🎯 x\n' > "${TMP}/msg"
    PATH="${STUB_BIN}:/usr/bin:/bin" run python3 "${PASTE}" --to codex --stdin < "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "peer-chat.py not on PATH"
}

# ------------------------------------------------------------- busy peer --

turn_state() { # turn_state <agent> <screen-file> — prints working|idle|unknown
    python3 - "${PASTE}" "$1" "$2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("paste", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(module.turn_state(open(sys.argv[3], encoding="utf-8").read(), sys.argv[2]))
PY
}

@test "turn_state: the Claude and Codex markers read live on 2026-09-30 classify working, idle, unknown" {
    printf '✻ Percolating… (37s · ↓ 1.6k tokens)\n❯ \n' > "${TMP}/s"
    [ "$(turn_state claude "${TMP}/s")" = working ]
    printf '✻ Pouncing… (5m 3s · ↓ 19.7k tokens)\n❯ [⧉ In settings.json]\n' > "${TMP}/s"
    [ "$(turn_state claude "${TMP}/s")" = working ]
    printf '     (ctrl+b to run in background)\n\n❯ \n' > "${TMP}/s"
    [ "$(turn_state claude "${TMP}/s")" = working ]
    printf '✻ Baked for 1m 59s · done 23:38\n\n❯ \n' > "${TMP}/s"
    [ "$(turn_state claude "${TMP}/s")" = idle ]
    printf '❯ [⧉ In settings.json]\n' > "${TMP}/s"
    [ "$(turn_state claude "${TMP}/s")" = idle ]
    printf 'unrecognized composer rendering\n' > "${TMP}/s"
    [ "$(turn_state claude "${TMP}/s")" = unknown ]
    printf '• Working (14s • esc to interrupt)\n\n› Ask Codex to do anything\n' > "${TMP}/s"
    [ "$(turn_state codex "${TMP}/s")" = working ]
    printf '• Working (2m 30s • Esc to interrupt)\n› Ask Codex to do anything\n' > "${TMP}/s"
    [ "$(turn_state codex "${TMP}/s")" = working ]
    printf '  Worked for 54s • 23:43\n\n› Ask Codex to do anything\n' > "${TMP}/s"
    [ "$(turn_state codex "${TMP}/s")" = idle ]
    printf '» Ask Codex to do anything\n' > "${TMP}/s"
    [ "$(turn_state codex "${TMP}/s")" = idle ]
    printf '1. Approve\n2. Deny\n' > "${TMP}/s"
    [ "$(turn_state codex "${TMP}/s")" = unknown ]
    printf '❯ \n' > "${TMP}/s"
    [ "$(turn_state shell "${TMP}/s")" = unknown ]
}

@test "busy peer: a working Codex screen prints the mid-turn warning and the paste still lands" {
    printf '• Working (14s • esc to interrupt)\n\n› Ask Codex to do anything\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" "peer-chat-paste: the peer is mid-turn; this send queues behind its current task"
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID}"
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "busy peer: a working Claude screen warns with the Claude markers" {
    cp "${FIX}/tree-pair-claude-claude.json" "${TMP}/tree.json"
    printf '✻ Pouncing… (5m 3s · ↓ 19.7k tokens)\n❯ [⧉ In settings.json]\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" "the peer is mid-turn"
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID}"
}

@test "busy peer: an idle or unknown screen prints no warning" {
    printf '  Worked for 54s • 23:43\n\n› Ask Codex to do anything\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_not_contains "${output}" "mid-turn"
    printf 'empty' > "${TMP}/state"
    printf 'unrecognized composer rendering\n' > "${TMP}/composer"
    send_file "${TMP}/msg"
    assert_status 0
    assert_not_contains "${output}" "mid-turn"
}

@test "busy peer: a refused send reads no screen and prints no warning" {
    seed_codex_ask "" "" ""
    printf '🎯 no disposition here\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_not_contains "${output}" "mid-turn"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session text"
}

# ----------------------------------------------------------------- queue --

codex_working_screen() {
    printf '• Working (2m 30s • esc to interrupt)\n› Ask Codex to do anything\n  tab to queue message\n  80%% context left\n' > "${TMP}/composer"
}

typed_keys() { od -An -c "${TMP}/typed.log" | tr -d ' \n'; }

@test "queue: --queue --slug to a working codex pastes and submits with Tab" {
    codex_working_screen
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --queue --slug seatos
    assert_status 0
    assert_contains "${output}" "queues behind its current task"
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID}"
    [ "$(typed_keys)" = '\t' ]
}

@test "queue: --queue to a codex screen that reads as unknown submits with Return" {
    printf '1. Approve\n2. Deny\n' > "${TMP}/composer"
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --queue
    assert_status 0
    assert_not_contains "${output}" "mid-turn"
    [ "$(typed_keys)" = '\n' ]
}

@test "queue: a codex that ends its turn during the paste wait gets Return, read after the paste" {
    codex_working_screen
    printf '  Worked for 54s • 23:43\n\n› Ask Codex to do anything\n' > "${TMP}/composer-after-paste"
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --queue
    assert_status 0
    assert_contains "${output}" "queues behind its current task"
    [ "$(typed_keys)" = '\n' ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "queue: --queue to an idle codex submits with Return" {
    printf '  Worked for 54s • 23:43\n\n› Ask Codex to do anything\n' > "${TMP}/composer"
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --queue
    assert_status 0
    [ "$(typed_keys)" = '\n' ]
}

@test "queue: --queue to a claude peer is refused, nothing pasted" {
    cp "${FIX}/tree-pair-claude-claude.json" "${TMP}/tree.json"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --queue --slug seatos
    assert_status 1
    assert_contains "${output}" "--queue works only when the recipient runs codex"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
}

# --------------------------------------------------------------- handoff --

@test "handoff: peer-chat.py --slug hands the send to the paste transport and its ledger" {
    printf '🔎 Processor.php:23\n\n❓ does a retry create a second bid?\n' > "${TMP}/msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --slug seatos --stdin < "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" '"asks": ["#left-001"]'
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID}"
    assert_contains "$(ledger_rows)" $'left-001\tleft\t'
    assert_not_contains "${output}" "unrecognized arguments"
}

@test "handoff: peer-chat.py --queue --slug to a working codex delivers through paste with Tab" {
    codex_working_screen
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --queue --slug seatos --stdin < "${TMP}/msg"
    assert_status 0
    assert_contains "$(cat "${TMP}/calls.log")" "session paste"
    assert_not_contains "${output}" "not recognisable"
    [ "$(typed_keys)" = '\t' ]
}

@test "handoff: peer-chat.py --queue with a path --message-file hands off, the path survives the adapter parser" {
    codex_working_screen
    mkdir -p "${TMP}/tmp/peer-chat/seatos"
    printf '🎯 the finding, verbatim\n\n🔎 CLEAN=$(x) | grep -f <(y)\n' > "${TMP}/tmp/peer-chat/seatos/01.msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --queue --message-file tmp/peer-chat/seatos/01.msg --slug seatos
    assert_status 0
    assert_contains "$(cat "${TMP}/clip-first-set")" '🔎 CLEAN=$(x) | grep -f <(y)'
    [ "$(typed_keys)" = '\t' ]
    [ -f "${TMP}/tmp/peer-chat/seatos/01.msg" ]
    assert_not_contains "${output}" "message file restored"
}

@test "handoff: --prepare-message ignores --queue and --slug, reserves the spool and pastes nothing" {
    export TMPDIR="${TMP}"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message peer-chat-left-q1aa.txt --queue
    assert_status 0
    assert_contains "${output}" '"messageFile"'
    run python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message=peer-chat-left-q1ab.txt --slug seatos
    assert_status 0
    assert_contains "${output}" '"messageFile"'
    assert_not_contains "$(cat "${TMP}/calls.log" 2>/dev/null)" "session paste"
}

@test "handoff: an abbreviated --slug is refused, never sent without its ledger" {
    printf '🎯 x\n' > "${TMP}/msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --stdin --slu seatos < "${TMP}/msg"
    assert_status 2
    assert_contains "${output}" "spell --slug and --queue in full"
    assert_not_contains "$(cat "${TMP}/calls.log" 2>/dev/null)" "session"
}

@test "handoff: peer-chat.py --slug=<topic> hands off like --slug <topic>" {
    printf '🔎 Processor.php:23\n\n❓ is the 409 retried at all?\n' > "${TMP}/msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --slug=seatos --stdin < "${TMP}/msg"
    assert_status 0
    assert_contains "$(ledger_rows)" $'left-001\tleft\t'
}

@test "handoff: the paste transport resolves through the handing adapter, not a copy on PATH" {
    unset PEER_CHAT_TRANSPORT
    py="$(python3 -c 'import sys; print(sys.executable)')"
    printf '🎯 x\n' > "${TMP}/msg"
    PATH="${STUB_BIN}:/usr/bin:/bin" run "${py}" "${PLUGIN}/scripts/peer-chat.py" --to peer --slug seatos --stdin < "${TMP}/msg"
    assert_status 0
    assert_not_contains "${output}" "not on PATH"
    assert_contains "$(cat "${TMP}/calls.log")" "session paste"
}

@test "handoff: PEER_CHAT_SLUG in the environment keeps peer-chat.py on its own transport" {
    export TMPDIR="${TMP}"
    PEER_CHAT_SLUG=seatos run python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message peer-chat-left-e4v1.txt
    assert_status 0
    assert_contains "${output}" '"messageFile"'
}

@test "handoff: peer-chat.py with no paste script beside it names the installer" {
    cp "${PLUGIN}/scripts/peer-chat.py" "${TMP}/peer-chat.py"
    cp "${PLUGIN}/scripts/vendor/peer-chat.py" "${TMP}/peer-chat-engine.py"
    printf '🎯 x\n' > "${TMP}/msg"
    run python3 "${TMP}/peer-chat.py" --to peer --slug seatos --stdin < "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "peer-chat-paste.py is missing beside peer-chat.py; run peer-chat-install.sh"
    assert_not_contains "$(cat "${TMP}/calls.log" 2>/dev/null)" "session paste"
}

# ------------------------------------------------------------- path form --

@test "path form: a body quoting \$(x), <(y) and a pipe sends verbatim and the file survives" {
    mkdir -p "${TMP}/tmp/peer-chat/seatos"
    printf '🎯 the finding, verbatim\n\n🔎 CLEAN=$(printf %%s $FILES | grep -Fxv -f <(partially_staged) || true)\n' > "${TMP}/tmp/peer-chat/seatos/03-left-body.msg"
    PEER_CHAT_WRAP=0 run python3 "${PASTE}" --to peer --message-file tmp/peer-chat/seatos/03-left-body.msg
    assert_status 0
    assert_contains "$(cat "${TMP}/clip-first-set")" '🔎 CLEAN=$(printf %s $FILES | grep -Fxv -f <(partially_staged) || true)'
    [ "$(sed -n 3p "${TMP}/tmp/peer-chat/seatos/03-left-body.msg")" = '🔎 CLEAN=$(printf %s $FILES | grep -Fxv -f <(partially_staged) || true)' ]
    assert_not_contains "${output}" "message file restored"
}

@test "path form: a symlink is refused before any paste" {
    printf '🎯 x\n' > "${TMP}/real.msg"
    ln -s "${TMP}/real.msg" "${TMP}/link.msg"
    run python3 "${PASTE}" --to peer --message-file "${TMP}/link.msg"
    assert_status 1
    assert_contains "${output}" "message path must be an owned regular file, not a symlink"
    assert_not_contains "$(cat "${TMP}/calls.log" 2>/dev/null)" "session paste"
}

@test "path form: a file owned by another user is refused before any paste" {
    [ "$(id -u)" -ne 0 ] || skip "root owns everything"
    [ "$(stat -f %u /etc/hosts 2>/dev/null || stat -c %u /etc/hosts)" != "$(id -u)" ] || skip "/etc/hosts is ours"
    run python3 "${PASTE}" --to peer --message-file /etc/hosts
    assert_status 1
    assert_contains "${output}" "message path must be an owned regular file, not a symlink"
    assert_not_contains "$(cat "${TMP}/calls.log" 2>/dev/null)" "session paste"
}

@test "path form: a directory and an oversized file are refused with their own reasons" {
    run python3 "${PASTE}" --to peer --message-file "${TMP}/"
    assert_status 1
    assert_contains "${output}" "message path must be an owned regular file, not a symlink"
    head -c 65537 /dev/zero | tr '\0' 'x' > "${TMP}/big.msg"
    run python3 "${PASTE}" --to peer --message-file "${TMP}/big.msg"
    assert_status 1
    assert_contains "${output}" "message path exceeds 65536 bytes"
    assert_not_contains "$(cat "${TMP}/calls.log" 2>/dev/null)" "session paste"
}

@test "path form: a ledger refusal leaves the file as it was, no restore message" {
    seed_codex_ask "" "" ""
    printf '🎯 the guard is blind across bids\n' > "${TMP}/body.msg"
    run python3 "${PASTE}" --to codex --message-file "${TMP}/body.msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "refused: the peer's asks below have no disposition"
    assert_not_contains "${output}" "message file restored"
    [ "$(cat "${TMP}/body.msg")" = "🎯 the guard is blind across bids" ]
}

# ------------------------------------------------------------------ shape --

@test "wrap: a long prose line breaks at a word boundary with a continuation indent, a long token stays whole" {
    printf '🎯 the double payment guard groups by bid so a purchase retried after a 409 lands a second PAID row on a second bid\n\n🔎 front/src/Service/Payment/DoublePaymentProcessor/VeryLongClassNameHere.php:23-31\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    pasted="$(cat "${TMP}/clip-first-set")"
    assert_contains "${pasted}" $'🎯 the double payment guard groups by bid so a\n   purchase retried after a 409 lands a second\n   PAID row on a second bid'
    assert_contains "${pasted}" $'\n🔎 front/src/Service/Payment/DoublePaymentProcessor/VeryLongClassNameHere.php:23-31'
    assert_contains "${output}" '"lines": 5'
}

@test "wrap: PEER_CHAT_WRAP=0 sends the line unbroken" {
    printf '🎯 the double payment guard groups by bid so a purchase retried after a 409 lands twice\n' > "${TMP}/msg"
    PEER_CHAT_WRAP=0 run python3 "${PASTE}" --to codex --stdin < "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" '"lines": 1'
}

@test "rule B: a ❓ with no 🔎 warns and still sends; a ❓ beside a 🔎 does not" {
    printf '❓ does a retry create a second bid?\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" "rule B"
    printf '🔎 Processor.php:23\n\n❓ does a retry create a second bid?\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_not_contains "${output}" "rule B"
    assert_contains "${output}" "no --slug"
}

# ----------------------------------------------------------------- ledger --

LEDGER="tmp/peer-chat/seatos/state.json"

ledger_rows() {
    jq -r '.asks[] | [.id,.asked_by,.sent_at,.disposition,.deferred_due,.reason,.question] | @tsv' "${TMP}/${LEDGER}"
}

seed_codex_ask() { # seed_codex_ask <disposition> <due> <reason>
    mkdir -p "${TMP}/tmp/peer-chat/seatos"
    printf 'id\tasked_by\tsent_at\tdisposition\tdue\treason\tquestion\n' > "${TMP}/tmp/peer-chat/seatos/asks.tsv"
    printf 'codex-001\tcodex\t2026-09-10T08:00:00Z\t%s\t%s\t%s\tdoes the refund path reuse the bid?\n' "$1" "$2" "$3" >> "${TMP}/tmp/peer-chat/seatos/asks.tsv"
}

@test "ledger: --slug issues a topic-scoped id to every ❓, writes the row after delivery, reports it" {
    printf '🔎 Processor.php:23\n\n❓ does a retry create a second bid?\n\n❓ is the 409 retried at all?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    pasted="$(cat "${TMP}/clip-first-set")"
    assert_contains "${pasted}" "❓ #left-001 does a retry create a second bid?"
    assert_contains "${pasted}" "❓ #left-002 is the 409 retried at all?"
    assert_contains "${output}" '"asks": ["#left-001", "#left-002"]'
    assert_contains "$(ledger_rows)" $'left-001\tleft\t'
    assert_contains "$(ledger_rows)" $'\t\t\t\tdoes a retry create a second bid?'
    assert_not_contains "${output}" "no --slug"
}

@test "ledger: an unconfirmed delivery preserves an unresolved claim and arms no timer" {
    touch "${TMP}/paste-ignored"
    printf '❓ x?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 1
    [ "$(jq '.messages | length' "${TMP}/${LEDGER}")" = 1 ]
    [ "$(jq -r '.messages[] | .state' "${TMP}/${LEDGER}")" = uncertain ]
    [ "$(jq '.timers | length' "${TMP}/${LEDGER}")" = 0 ]
}

@test "budgets: a blocking send stamps sources and arms only on submit_sent" {
    printf '🔎 evidence\n❓ return the result\n' > "${TMP}/msg"
    PEER_CHAT_WAKE_MINUTES=3 send_file "${TMP}/msg" --slug seatos --blocking --deadline 20m --est-grace 5m
    assert_status 0
    assert_contains "$(cat "${TMP}/clip-first-set")" "deadline 20m after"
    assert_contains "$(cat "${TMP}/clip-first-set")" "(flag)"
    assert_contains "$(cat "${TMP}/clip-first-set")" "(agent)"
    [ "$(jq -r '.timers["left-001"].budgets.wake.source' "${TMP}/${LEDGER}")" = env ]
    jq -e '.timers["left-001"].budgets.wake.seconds == 180' "${TMP}/${LEDGER}"
    [ "$(jq -r '.asks[0].question' "${TMP}/${LEDGER}")" = "return the result" ]
    [ "$(jq -r '.messages[].state' "${TMP}/${LEDGER}")" = submit_sent ]
    [ "$(jq -r '.timers["left-001"].armed_at' "${TMP}/${LEDGER}")" = "$(jq -r '.messages[].submitted_at' "${TMP}/${LEDGER}")" ]
}

@test "budgets: missing blocking values refuse before any paste" {
    printf '❓ result?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --blocking --deadline 20m
    assert_status 2
    assert_contains "${output}" "grace"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
    [ ! -f "${TMP}/typed.log" ]
}

@test "budgets: a foreign repo send uses the explicit coordinator profile and state" {
    printf '🎯 initialize\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    printf '{"stall_minutes":2,"grace_minutes":1,"wake_minutes":0.5}\n' > "${TMP}/.peer-chat.json"
    mkdir "${TMP}/foreign"
    cd "${TMP}/foreign"
    printf '❓ result?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --state "${TMP}/${LEDGER}" --blocking
    assert_status 0
    [ "$(jq -r '.timers["left-001"].budgets.deadline.source' "${TMP}/${LEDGER}")" = profile ]
    jq -e '.timers["left-001"].budgets.deadline.seconds == 120' "${TMP}/${LEDGER}"
    [ ! -d "${TMP}/foreign/tmp/peer-chat" ]
}

@test "delivery: an idempotency replay cannot paste or submit twice" {
    printf '🎯 a result\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --key stable
    assert_status 0
    send_file "${TMP}/msg" --slug seatos --key stable
    assert_status 2
    assert_contains "${output}" "already claimed"
    [ "$(grep -c '^session paste ' "${TMP}/calls.log")" = 1 ]
    [ "$(jq '.messages | length' "${TMP}/${LEDGER}")" = 1 ]
}

@test "delivery: an unresolved paste cannot be hidden by the next send" {
    touch "${TMP}/paste-ignored"
    printf '🎯 uncertain\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 1
    printf '🎯 next result\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "earlier delivery is unresolved"
    [ "$(grep -c '^session paste ' "${TMP}/calls.log")" = 1 ]
    [ "$(jq '.messages | length' "${TMP}/${LEDGER}")" = 1 ]
}

@test "delivery: state.lock is available throughout clipboard and pane IO" {
    cat > "${TMP}/check-lock.py" <<'PY'
import fcntl, pathlib, sys
path = pathlib.Path(sys.argv[1])
if path.exists():
    with path.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path.with_suffix('.checked').write_text('storage lock free during IO')
PY
    stub pbcopy "python3 '${TMP}/check-lock.py' '${TMP}/tmp/peer-chat/seatos/state.lock' || exit 9; cat > '${TMP}/clip'; grep -q '^Chat from' '${TMP}/clip' || exit 0; cp '${TMP}/clip' '${TMP}/clip-last-set'"
    printf '🎯 lock check\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    [ -f "${TMP}/tmp/peer-chat/seatos/state.checked" ]
}

@test "ledger: a new ask from the peer with no disposition refuses the send before anything is written" {
    seed_codex_ask "" "" ""
    printf '🎯 the guard is blind across bids\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "refused: the peer's asks below have no disposition"
    assert_contains "${output}" "#codex-001: does the refund path reuse the bid?"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
}

@test "ledger: answered closes the ask and keeps the reason" {
    seed_codex_ask "" "" ""
    printf '🎯 #codex-001 answered: no, the refund path opens a new bid\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    assert_contains "${output}" '"disposed": ["#codex-001"]'
    assert_contains "$(ledger_rows)" $'codex-001\tright\t2026-09-10T08:00:00Z\tanswered\t\tno, the refund path opens a new bid\t'
}

@test "ledger: deferred keeps the ask open with a due time, and the next send is not refused" {
    seed_codex_ask "" "" ""
    printf '#codex-001 deferred(after the fixture run)\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    row="$(ledger_rows | grep '^codex-001')"
    assert_contains "${row}" $'\tdeferred\t20'
    assert_contains "${row}" $'Z\tafter the fixture run\t'
    printf '🎯 next claim\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    assert_not_contains "$(cat "${TMP}/clip-last-set")" "overdue"
}

@test "ledger: a deferral past its due time is prepended to the deferrer's next send as overdue" {
    seed_codex_ask deferred 2026-09-10T08:20:00Z "after the fixture run"
    printf '🎯 next claim\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    [ "$(head -1 "${TMP}/clip-first-set")" = "Chat from claude (left): overdue: #codex-001 deferred(after the fixture" ]
    [ "$(sed -n 2p "${TMP}/clip-first-set")" = "   run): does the refund path reuse the bid?" ]
    [ "$(sed -n 4p "${TMP}/clip-first-set")" = "🎯 next claim" ]
}

@test "ledger: a refused --message-file send restores the spool file so the body can be fixed and resent" {
    export TMPDIR="${TMP}"
    seed_codex_ask "" "" ""
    python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message peer-chat-codex-a91f.txt >/dev/null
    spool="$(ls -d "${TMP}"/agterm-peer-chat-*)"
    printf '🎯 the guard is blind across bids\n' > "${spool}/peer-chat-codex-a91f.txt"
    run python3 "${PASTE}" --to codex --message-file peer-chat-codex-a91f.txt --slug seatos
    assert_status 2
    assert_contains "${output}" "message file restored: peer-chat-codex-a91f.txt"
    [ "$(cat "${spool}/peer-chat-codex-a91f.txt")" = "🎯 the guard is blind across bids" ]
}

# ------------------------------------------------------------- symmetry --

@test "pair: claude+claude, left sends to right with the Claude protocol and its own label" {
    cp "${FIX}/tree-pair-claude-claude.json" "${TMP}/tree.json"
    printf '❯ \n' > "${TMP}/composer"
    printf '🎯 same harness on both sides\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/clip-first-set")" = "Chat from claude (left): 🎯 same harness on both sides" ]
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID}"
}

@test "pair: codex+codex, right sends to left with the Codex protocol" {
    cp "${FIX}/tree-pair-codex-codex.json" "${TMP}/tree.json"
    printf '🎯 codex to codex\n' > "${TMP}/msg"
    AGTERM_PANE=right send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/clip-first-set")" = "Chat from codex (right): 🎯 codex to codex" ]
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane left --target ${SID}"
}

@test "pair: PEER_CHAT_NAME names the sender in the label" {
    printf '🎯 named\n' > "${TMP}/msg"
    PEER_CHAT_NAME="claude opus" send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/clip-first-set")" = "Chat from claude opus: 🎯 named" ]
}

@test "pair: legacy --to claude refuses when both panes run claude, before any paste" {
    cp "${FIX}/tree-pair-claude-claude.json" "${TMP}/tree.json"
    printf '🎯 x\n' > "${TMP}/msg"
    run python3 "${PASTE}" --to claude --stdin < "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "2 panes run claude"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
}

@test "pair: --to the sender's own pane is refused" {
    printf '🎯 x\n' > "${TMP}/msg"
    run python3 "${PASTE}" --to left --stdin < "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "resolves to this pane (left)"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
}

@test "pair: a peer pane running no known harness is refused before any paste" {
    cp "${FIX}/tree-split-busy.json" "${TMP}/tree.json"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "the right pane runs no known peer"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
}

@test "pair: a sender outside a left or right pane is refused" {
    printf '🎯 x\n' > "${TMP}/msg"
    AGTERM_PANE=scratch send_file "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "not left or right"
}

@test "ledger: new ids continue after legacy #claude-NNN asks, which now belong to the left pane" {
    mkdir -p "${TMP}/tmp/peer-chat/seatos"
    printf 'id\tasked_by\tsent_at\tdisposition\tdue\treason\tquestion\n' > "${TMP}/tmp/peer-chat/seatos/asks.tsv"
    printf 'claude-002\tclaude\t2026-09-10T08:00:00Z\tanswered\t\tyes\tolder ask\n' >> "${TMP}/tmp/peer-chat/seatos/asks.tsv"
    printf '🔎 Processor.php:23\n\n❓ next question\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    assert_contains "$(cat "${TMP}/clip-first-set")" "❓ #left-003 next question"
    assert_contains "$(ledger_rows)" $'claude-002\tleft\t'
}


@test "recovery: missing target preserves spool and verified selectors deliver it once" {
    export TMPDIR="${TMP}"
    python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message peer-chat-recovery.txt >/dev/null
    spool="$(ls -d "${TMP}"/agterm-peer-chat-*)/peer-chat-recovery.txt"
    printf '🎯 recovered conversation\n\n🔎 exact body preserved\n' > "${spool}"
    cp "${spool}" "${TMP}/expected"
    export AGTERM_SESSION_ID=deleted-session
    run python3 "${PASTE}" --to peer --message-file peer-chat-recovery.txt --slug recovery
    assert_status 1
    assert_contains "${output}" "not found"
    assert_contains "${output}" "message file restored"
    cmp "${spool}" "${TMP}/expected"
    [ ! -f "${TMP}/typed.log" ]
    assert_not_contains "$(cat "${TMP}/calls.log")" 'session paste'
    [ ! -f "${TMP}/tmp/peer-chat/recovery/asks.tsv" ]

    run python3 "${PASTE}" --to peer --message-file peer-chat-recovery.txt --slug recovery --session "${SID}" --window win-1
    assert_status 0
    [ ! -e "${spool}" ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    assert_contains "$(cat "${TMP}/clip-last-set")" 'recovered conversation'
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID} --window win-1"
}

@test "recovery: ambiguous selector preserves spool and never chooses the active pane" {
    export TMPDIR="${TMP}"
    python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message peer-chat-ambiguous.txt >/dev/null
    spool="$(ls -d "${TMP}"/agterm-peer-chat-*)/peer-chat-ambiguous.txt"
    printf '🎯 do not guess\n' > "${spool}"
    python3 - "${TMP}/tree.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
tree = json.loads(p.read_text())
p.write_text(json.dumps([tree, tree]))
PY
    run python3 "${PASTE}" --to peer --message-file peer-chat-ambiguous.txt
    assert_status 1
    assert_contains "${output}" "ambiguous"
    [ "$(cat "${spool}")" = '🎯 do not guess' ]
    [ ! -f "${TMP}/typed.log" ]
    assert_not_contains "$(cat "${TMP}/calls.log")" 'session paste'
}

@test "recovery: unconfirmed paste preserves spool without submitting or retrying" {
    export TMPDIR="${TMP}"
    python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message peer-chat-unconfirmed.txt >/dev/null
    spool="$(ls -d "${TMP}"/agterm-peer-chat-*)/peer-chat-unconfirmed.txt"
    printf '🎯 inspect before retrying\n' > "${spool}"
    touch "${TMP}/paste-ignored"
    run python3 "${PASTE}" --to peer --message-file peer-chat-unconfirmed.txt
    assert_status 1
    assert_contains "${output}" "paste not confirmed"
    assert_contains "${output}" "inspect the failure and peer screen before retrying"
    [ "$(cat "${spool}")" = '🎯 inspect before retrying' ]
    [ ! -f "${TMP}/typed.log" ]
    [ "$(grep -c '^session paste ' "${TMP}/calls.log")" -eq 1 ]
}

# --recover-delivery runs in the receiving pane (left = claude in tree-split-codex.json).
RECORDED=$'Chat from codex (right): 🎯 the answer\n\n🔎 path.go:12\n   the reasoning'

outbox() { printf '%s' "${TMP}/tmp/peer-chat/t/outbox-${SID}-$1"; }

recorded_outbox() {
    mkdir -p "${TMP}/tmp/peer-chat/t"
    printf '%s' "${RECORDED}" > "$(outbox left.msg)"
}

claude_composer() { # claude_composer <file> <content line>...
    local file="$1"
    shift
    { printf '❯ %s\n' "$1"; shift; for line in "$@"; do printf '  %s\n' "$line"; done
      printf '%s\n' '────────────────────────────────' '  ? for shortcuts'; } > "${file}"
}

recorded_composer() { claude_composer "$1" 'Chat from codex (right): 🎯 the' 'answer' '🔎 path.go:12' 'the reasoning'; }

# The second `session text` read shows composer-next, as when the user types between the two reads.
swap_on_second_read() {
    local hook="[ -f '${TMP}/composer-next' ] \&\& [ -f '${TMP}/read-once' ] \&\& cp '${TMP}/composer-next' '${TMP}/composer'; touch '${TMP}/read-once';"
    sed -i.bak "s|^            \*) cat |            *) ${hook} cat |" "${STUB_BIN}/agtermctl"
    grep -q 'read-once' "${STUB_BIN}/agtermctl"
}

recover() { run python3 "${PASTE}" --to peer --recover-delivery --slug t; }

@test "recover: a send with --slug records the exact pasted text for the receiving session and pane" {
    printf '🎯 one\n\n🔎 two\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug t
    assert_status 0
    [ "$(cat "$(outbox right.msg)")" = "$(cat "${TMP}/clip-first-set")" ]
    [ "$(stat -f %Lp "$(outbox right.msg)")" = 600 ]
}

@test "recover: the composer holding exactly the recorded message, rewrapped, gets one Return" {
    recorded_outbox
    recorded_composer "${TMP}/composer"
    recover
    assert_status 0
    assert_contains "${output}" '"recovered": true'
    assert_contains "$(cat "${TMP}/calls.log")" 'session type --stdin --pane left'
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ -f "$(outbox left.recovered)" ]
    [ ! -f "$(outbox left.msg)" ]
}

@test "recover: extra text or only a prefix leaves the composer untouched" {
    recorded_outbox
    for composer in extra prefix; do
        if [ "$composer" = extra ]; then
            claude_composer "${TMP}/composer" 'Chat from codex (right): 🎯 the answer' '🔎 path.go:12' 'the reasoning' 'my own words'
        else
            claude_composer "${TMP}/composer" 'Chat from codex (right): 🎯 the answer'
        fi
        recover
        assert_status 1
        assert_contains "${output}" 'composer holds other text; left untouched'
        [ ! -f "${TMP}/typed.log" ]
        [ -f "$(outbox left.msg)" ]
    done
}

@test "recover: a collapsed paste is never submitted, whatever its size" {
    recorded_outbox
    for marker in '[Pasted text #1 +3 lines]' '[Pasted text #1 +4 lines]'; do
        claude_composer "${TMP}/composer" "${marker}"
        recover
        assert_status 1
        assert_contains "${output}" 'collapsed paste whose text cannot be checked'
    done
    [ ! -f "${TMP}/typed.log" ]
    [ -f "$(outbox left.msg)" ]
}

@test "recover: text that changes between the two composer reads is left untouched" {
    recorded_outbox
    recorded_composer "${TMP}/composer"
    claude_composer "${TMP}/composer-next" 'Chat from codex (right): 🎯 the answer' '🔎 path.go:12' 'the reasoning' 'typed meanwhile'
    swap_on_second_read
    recover
    assert_status 1
    assert_contains "${output}" 'composer holds other text; left untouched'
    [ ! -f "${TMP}/typed.log" ]
}

@test "recover: waits for the transport lock, so the outbox cannot change under it" {
    recorded_outbox
    recorded_composer "${TMP}/composer"
    python3 - "${TMP}/tmp/peer-chat/t/outbox-${SID}-left.delivery.lock" "${TMP}/calls.log" "${TMP}/held" <<'PY2' &
import fcntl, sys, time
from pathlib import Path
with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    Path(sys.argv[3]).touch()
    time.sleep(1.5)
    with open(sys.argv[2], "a") as log:
        log.write("holder released\n")
    fcntl.flock(lock, fcntl.LOCK_UN)
PY2
    holder=$!
    while [ ! -f "${TMP}/held" ]; do sleep 0.05; done
    recover
    wait "${holder}"
    assert_status 0
    released=$(grep -n 'holder released' "${TMP}/calls.log" | cut -d: -f1)
    typed=$(grep -n '^session type' "${TMP}/calls.log" | cut -d: -f1)
    [ "${typed}" -gt "${released}" ]
}

@test "recover: an empty composer or no recorded message presses nothing and exits 3" {
    claude_composer "${TMP}/composer" ''
    recover
    assert_status 3
    assert_contains "${output}" 'no recorded message for the left pane'
    recorded_outbox
    recover
    assert_status 3
    assert_contains "${output}" 'composer empty; nothing to recover'
    [ ! -f "${TMP}/typed.log" ]
}

@test "recover: --recover-delivery without --slug is a usage error" {
    run python3 "${PASTE}" --to peer --recover-delivery
    assert_status 2
    assert_contains "${output}" '--recover-delivery needs --slug'
}
