#!/usr/bin/env bats
#
# tests/test-peer-chat-paste.bats
#
# peer-chat-paste.py loads the vendored transport as a module and drives agterm through it, so
# the suite stubs agtermctl with a state machine (empty composer, pasted, submitted).
# It records bracketed paste bytes and submit keys separately and rejects clipboard calls.
# A draft, a suggestion or a hint in the composer never blocks either target. A pane with no live
# composer (a question dialog, an approval modal, an unknown rendering) holds the send: the stub
# shows `dialog` for the first `dialog-reads` reads before the paste, for the pasted reads from
# `dialog-from` up to `dialog-until`, and `pasted-screen` verbatim from read `pasted-screen-from`.
# Otherwise a pasted read draws the text inside the composer, as tests/fixtures/peer-chat/pasted-pane.py does.

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
    export PEER_CHAT_DELIVERY_POLL=0.1 PEER_CHAT_LOCK_WAIT=0.5
    unset AGTERM_WINDOW_ID PEER_CHAT_DELIVERY_WAIT PEER_CHAT_COMPOSER_GATE
    : > "${TMP}/paste-calls.log"
    printf 'empty' > "${TMP}/state"
    cp "${FIX}/tree-split-codex.json" "${TMP}/tree.json"
    stub pbcopy "echo pbcopy >> '${TMP}/clipboard-calls'; exit 1"
    stub pbpaste "echo pbpaste >> '${TMP}/clipboard-calls'; exit 1"
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
        screen="${TMP}/composer"
        [ -f "\$screen" ] || screen="${FIX}/codex-pane-empty.txt"
        left="\$(cat "${TMP}/dialog-reads" 2>/dev/null || echo 0)"
        if [ "\$state" != pasted ] && [ "\$left" -gt 0 ]; then
            echo \$((left - 1)) > "${TMP}/dialog-reads"
            cat "${TMP}/dialog"
            exit 0
        fi
        case "\$state" in
            pasted)
                read_no="\$(cat "${TMP}/pasted-reads" 2>/dev/null || echo 0)"
                echo \$((read_no + 1)) > "${TMP}/pasted-reads"
                if [ -f "${TMP}/dialog-from" ] && [ "\$read_no" -ge "\$(cat "${TMP}/dialog-from")" ] && [ "\$read_no" -lt "\$(cat "${TMP}/dialog-until")" ]; then
                    cat "${TMP}/dialog"
                elif [ -f "${TMP}/dialog-on-even-reads" ] && [ "\$read_no" -ge 2 ] && [ \$((read_no % 2)) -eq 0 ]; then
                    cat "${TMP}/dialog"
                elif [ -f "${TMP}/pasted-screen" ] && [ "\$read_no" -ge "\$(cat "${TMP}/pasted-screen-from" 2>/dev/null || echo 0)" ]; then
                    cat "${TMP}/pasted-screen"
                else
                    python3 "${FIX}/pasted-pane.py" "${TMP}/pasted-body" "\$screen"
                fi ;;
            busy) printf '› half a line the user typed\n \n  footer row\n' ;;
            submitted) cat "${TMP}/after-submit" 2>/dev/null || cat "${FIX}/codex-pane-empty.txt" ;;
            *) cat "\$screen" ;;
        esac ;;
    "session type")
        cat > "${TMP}/typed-input"
        payload="\$(cat "${TMP}/typed-input")"
        start=\$'\\033[200~'
        end=\$'\\033[201~'
        case "\$payload" in
            "\$start"*"\$end")
                printf '%s\n' "\$*" >> "${TMP}/paste-calls.log"
                cp "${TMP}/typed-input" "${TMP}/paste-input"
                payload="\${payload#"\$start"}"
                printf '%s' "\${payload%"\$end"}" > "${TMP}/pasted-body"
                [ -f "${TMP}/pasted-first" ] || cp "${TMP}/pasted-body" "${TMP}/pasted-first"
                if [ -f "${TMP}/check-lock.py" ]; then
                    python3 "${TMP}/check-lock.py" "${TMP}/tmp/peer-chat/seatos/state.lock" || exit 9
                fi
                [ -f "${TMP}/paste-ignored" ] || printf 'pasted' > "${TMP}/state"
                [ ! -f "${TMP}/composer-after-paste" ] || cp "${TMP}/composer-after-paste" "${TMP}/composer"
                echo 0 > "${TMP}/pasted-reads" ;;
            *)
                cat "${TMP}/typed-input" >> "${TMP}/typed.log"
                cat "${TMP}/pasted-reads" > "${TMP}/typed-at-read" 2>/dev/null
                printf 'submitted' > "${TMP}/state" ;;
        esac
        echo ok ;;
    notify\ *) [ ! -f "${TMP}/notify-fails" ] || exit 9; echo ok ;;
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

@test "paste: a multi-line ledger send types one bracketed body with the clipboard unavailable" {
    printf '🎯 the guard is blind across bids\n\n🔎 DoublePaymentProcessor.php:23-31\n\n❓ does a retry create a second bid?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    assert_contains "${output}" '"lines": 5'
    expected=$'Chat from claude (left): 🎯 the guard is blind across bids\n\n🔎 DoublePaymentProcessor.php:23-31\n\n❓ #left-001 does a retry create a second bid?'
    printf '\033[200~%s\033[201~' "$expected" > "${TMP}/expected-paste"
    cmp "${TMP}/expected-paste" "${TMP}/paste-input"
    [ "$(paste_calls)" = 1 ]
    [ ! -e "${TMP}/clipboard-calls" ]
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane right --target ${SID}"
    cmp <(printf '\n') "${TMP}/typed.log"
    [ "$(cat "${TMP}/state")" = submitted ]
    [ "$(message_states)" = submit_sent ]
}

@test "paste: an existing label is not doubled and trailing blank lines are dropped" {
    printf 'Chat from claude (left): 🎯 one line\n\n\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/pasted-first")" = "Chat from claude (left): 🎯 one line" ]
}

@test "paste: existing draft text does not block paste or submit" {
    printf 'busy' > "${TMP}/state"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    [ "$(paste_calls)" = 1 ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

composer_matrix() {
    local target="$1" prompt pane sender state after expected_label box_end=''
    if [ "$target" = claude ]; then
        prompt='❯'; pane=left; sender=right; expected_label='Chat from codex (right):'
        box_end=$'────────────────────────────────\n  ? for shortcuts\n'
    else
        prompt='›'; pane=right; sender=left; expected_label='Chat from claude (left):'
    fi
    for state in empty suggestion startup_hint ide_context draft multiline queued; do
        case "$state" in
            empty) printf '%s \n' "$prompt" > "${TMP}/composer" ;;
            suggestion) printf '%s keep grilling, dont wait for me\n' "$prompt" > "${TMP}/composer" ;;
            startup_hint) printf '%s Try "fix a bug"\n' "$prompt" > "${TMP}/composer" ;;
            ide_context) printf '%s ⧉ In file.php\n' "$prompt" > "${TMP}/composer" ;;
            draft) printf '%s half a line the user typed\n' "$prompt" > "${TMP}/composer" ;;
            multiline) printf '%s draft line one\n  draft line two\n%s' "$prompt" "$box_end" > "${TMP}/composer" ;;
            queued) printf '%s Press up to edit queued messages\n' "$prompt" > "${TMP}/composer" ;;
        esac
        for after in empty occupied; do
            printf 'empty' > "${TMP}/state"
            : > "${TMP}/calls.log"
            : > "${TMP}/paste-calls.log"
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
            assert_contains "$(cat "${TMP}/pasted-body")" "$expected_label"
            assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane ${pane} --target ${SID}"
            [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
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

@test "paste: an unconfirmed paste gets no submit key" {
    touch "${TMP}/paste-ignored"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "paste not confirmed"
    [ ! -f "${TMP}/typed.log" ]
}

@test "paste: a tab becomes a space, CR and other control characters are dropped, the send goes through" {
    printf '🎯 x\ty\r\n\n🔎 a\033[201~b\r\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    [ "$(head -1 "${TMP}/pasted-first")" = "Chat from claude (left): 🎯 x y" ]
    [ "$(tail -1 "${TMP}/pasted-first")" = "🔎 a[201~b" ]
    ! grep -q $'\r' "${TMP}/pasted-first"
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
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane right --target ${SID}"
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "busy peer: a working Claude screen warns with the Claude markers" {
    cp "${FIX}/tree-pair-claude-claude.json" "${TMP}/tree.json"
    printf '✻ Pouncing… (5m 3s · ↓ 19.7k tokens)\n❯ [⧉ In settings.json]\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" "the peer is mid-turn"
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane right --target ${SID}"
}

@test "busy peer: an idle or unknown screen prints no warning" {
    printf '  Worked for 54s • 23:43\n\n› Ask Codex to do anything\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_not_contains "${output}" "mid-turn"
    printf 'empty' > "${TMP}/state"
    printf 'unrecognized composer rendering\n' > "${TMP}/composer"
    PEER_CHAT_COMPOSER_GATE=off send_file "${TMP}/msg"
    assert_status 0
    assert_not_contains "${output}" "mid-turn"
}

@test "busy peer: a refused send prints no warning and pastes nothing" {
    seed_codex_ask "" "" ""
    printf '🎯 no disposition here\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_not_contains "${output}" "mid-turn"
    [ "$(paste_calls)" = 0 ]
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
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane right --target ${SID}"
    [ "$(typed_keys)" = '\t' ]
}

@test "queue: --queue to a codex screen that reads as unknown submits with Return once the gate is off" {
    printf '1. Approve\n2. Deny\n' > "${TMP}/composer"
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    PEER_CHAT_COMPOSER_GATE=off send_file "${TMP}/msg" --queue
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
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/typed.log" ]
}

# --------------------------------------------------------------- handoff --

@test "handoff: peer-chat.py --slug hands the send to the paste transport and its ledger" {
    printf '🔎 Processor.php:23\n\n❓ does a retry create a second bid?\n' > "${TMP}/msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --slug seatos --stdin < "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" '"asks": ["#left-001"]'
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane right --target ${SID}"
    assert_contains "$(ledger_rows)" $'left-001\tleft\t'
    assert_not_contains "${output}" "unrecognized arguments"
}

@test "handoff: peer-chat.py --queue --slug to a working codex delivers through paste with Tab" {
    codex_working_screen
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --queue --slug seatos --stdin < "${TMP}/msg"
    assert_status 0
    [ "$(paste_calls)" = 1 ]
    assert_not_contains "${output}" "not recognisable"
    [ "$(typed_keys)" = '\t' ]
}

@test "handoff: peer-chat.py --queue with a path --message-file hands off, the path survives the adapter parser" {
    codex_working_screen
    mkdir -p "${TMP}/tmp/peer-chat/seatos"
    printf '🎯 the finding, verbatim\n\n🔎 CLEAN=$(x) | grep -f <(y)\n' > "${TMP}/tmp/peer-chat/seatos/01.msg"
    run python3 "${PLUGIN}/scripts/peer-chat.py" --to peer --queue --message-file tmp/peer-chat/seatos/01.msg --slug seatos
    assert_status 0
    assert_contains "$(cat "${TMP}/pasted-first")" '🔎 CLEAN=$(x) | grep -f <(y)'
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
    [ "$(paste_calls)" = 0 ]
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
    [ "$(paste_calls)" = 1 ]
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
    [ "$(paste_calls)" = 0 ]
}

# ------------------------------------------------------------- path form --

@test "path form: a body quoting \$(x), <(y) and a pipe sends verbatim and the file survives" {
    mkdir -p "${TMP}/tmp/peer-chat/seatos"
    printf '🎯 the finding, verbatim\n\n🔎 CLEAN=$(printf %%s $FILES | grep -Fxv -f <(partially_staged) || true)\n' > "${TMP}/tmp/peer-chat/seatos/03-left-body.msg"
    PEER_CHAT_WRAP=0 run python3 "${PASTE}" --to peer --message-file tmp/peer-chat/seatos/03-left-body.msg
    assert_status 0
    assert_contains "$(cat "${TMP}/pasted-first")" '🔎 CLEAN=$(printf %s $FILES | grep -Fxv -f <(partially_staged) || true)'
    [ "$(sed -n 3p "${TMP}/tmp/peer-chat/seatos/03-left-body.msg")" = '🔎 CLEAN=$(printf %s $FILES | grep -Fxv -f <(partially_staged) || true)' ]
    assert_not_contains "${output}" "message file restored"
}

@test "path form: a symlink is refused before any paste" {
    printf '🎯 x\n' > "${TMP}/real.msg"
    ln -s "${TMP}/real.msg" "${TMP}/link.msg"
    run python3 "${PASTE}" --to peer --message-file "${TMP}/link.msg"
    assert_status 1
    assert_contains "${output}" "message path must be an owned regular file, not a symlink"
    [ "$(paste_calls)" = 0 ]
}

@test "path form: a file owned by another user is refused before any paste" {
    [ "$(id -u)" -ne 0 ] || skip "root owns everything"
    [ "$(stat -f %u /etc/hosts 2>/dev/null || stat -c %u /etc/hosts)" != "$(id -u)" ] || skip "/etc/hosts is ours"
    run python3 "${PASTE}" --to peer --message-file /etc/hosts
    assert_status 1
    assert_contains "${output}" "message path must be an owned regular file, not a symlink"
    [ "$(paste_calls)" = 0 ]
}

@test "path form: a directory and an oversized file are refused with their own reasons" {
    run python3 "${PASTE}" --to peer --message-file "${TMP}/"
    assert_status 1
    assert_contains "${output}" "message path must be an owned regular file, not a symlink"
    head -c 65537 /dev/zero | tr '\0' 'x' > "${TMP}/big.msg"
    run python3 "${PASTE}" --to peer --message-file "${TMP}/big.msg"
    assert_status 1
    assert_contains "${output}" "message path exceeds 65536 bytes"
    [ "$(paste_calls)" = 0 ]
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
    pasted="$(cat "${TMP}/pasted-first")"
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
    pasted="$(cat "${TMP}/pasted-first")"
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
    assert_contains "$(cat "${TMP}/pasted-first")" "deadline 20m after"
    assert_contains "$(cat "${TMP}/pasted-first")" "(flag)"
    assert_contains "$(cat "${TMP}/pasted-first")" "(agent)"
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
    [ "$(paste_calls)" = 0 ]
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
    [ "$(paste_calls)" = 1 ]
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
    [ "$(paste_calls)" = 1 ]
    [ "$(jq '.messages | length' "${TMP}/${LEDGER}")" = 1 ]
}

@test "delivery: state.lock is available during the bracketed paste" {
    cat > "${TMP}/check-lock.py" <<'PY'
import fcntl, pathlib, sys
path = pathlib.Path(sys.argv[1])
if path.exists():
    with path.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path.with_suffix('.checked').write_text('storage lock free during IO')
PY
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
    [ "$(paste_calls)" = 0 ]
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
    assert_not_contains "$(cat "${TMP}/pasted-body")" "overdue"
}

@test "ledger: a deferral past its due time is prepended to the deferrer's next send as overdue" {
    seed_codex_ask deferred 2026-09-10T08:20:00Z "after the fixture run"
    printf '🎯 next claim\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    [ "$(head -1 "${TMP}/pasted-first")" = "Chat from claude (left): overdue: #codex-001 deferred(after the fixture" ]
    [ "$(sed -n 2p "${TMP}/pasted-first")" = "   run): does the refund path reuse the bid?" ]
    [ "$(sed -n 4p "${TMP}/pasted-first")" = "🎯 next claim" ]
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
    [ "$(cat "${TMP}/pasted-first")" = "Chat from claude (left): 🎯 same harness on both sides" ]
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane right --target ${SID}"
}

@test "pair: codex+codex, right sends to left with the Codex protocol" {
    cp "${FIX}/tree-pair-codex-codex.json" "${TMP}/tree.json"
    printf '🎯 codex to codex\n' > "${TMP}/msg"
    AGTERM_PANE=right send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/pasted-first")" = "Chat from codex (right): 🎯 codex to codex" ]
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane left --target ${SID}"
}

@test "pair: PEER_CHAT_NAME names the sender in the label" {
    printf '🎯 named\n' > "${TMP}/msg"
    PEER_CHAT_NAME="claude opus" send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/pasted-first")" = "Chat from claude opus: 🎯 named" ]
}

@test "pair: legacy --to claude refuses when both panes run claude, before any paste" {
    cp "${FIX}/tree-pair-claude-claude.json" "${TMP}/tree.json"
    printf '🎯 x\n' > "${TMP}/msg"
    run python3 "${PASTE}" --to claude --stdin < "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "2 panes run claude"
    [ "$(paste_calls)" = 0 ]
}

@test "pair: --to the sender's own pane is refused" {
    printf '🎯 x\n' > "${TMP}/msg"
    run python3 "${PASTE}" --to left --stdin < "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "resolves to this pane (left)"
    [ "$(paste_calls)" = 0 ]
}

@test "pair: a peer pane running no known harness is refused before any paste" {
    cp "${FIX}/tree-split-busy.json" "${TMP}/tree.json"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "the right pane runs no known peer"
    [ "$(paste_calls)" = 0 ]
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
    assert_contains "$(cat "${TMP}/pasted-first")" "❓ #left-003 next question"
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
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/tmp/peer-chat/recovery/asks.tsv" ]

    run python3 "${PASTE}" --to peer --message-file peer-chat-recovery.txt --slug recovery --session "${SID}" --window win-1
    assert_status 0
    [ ! -e "${spool}" ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    assert_contains "$(cat "${TMP}/pasted-body")" 'recovered conversation'
    assert_contains "$(cat "${TMP}/paste-calls.log")" "session type --stdin --pane right --target ${SID} --window win-1"
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
    [ "$(paste_calls)" = 0 ]
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
    [ "$(paste_calls)" -eq 1 ]
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
    [ "$(cat "$(outbox right.msg)")" = "$(cat "${TMP}/pasted-first")" ]
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
    PEER_CHAT_LOCK_WAIT=10 recover
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

# ----------------------------------------------------------- dialog gate --

HELD_NO_COMPOSER="peer-chat-paste: held: the peer pane shows no live composer (a dialog is open); nothing typed; rerun this send, --wait <dur> to wait longer"
GATE_OFF="peer-chat-paste: PEER_CHAT_COMPOSER_GATE=off: the dialog checks are skipped"
HELD_LOCK="peer-chat-paste: held: an earlier send is waiting for the peer's composer; nothing typed"
UNSUBMITTED_NO_COMPOSER="peer-chat-paste: pasted, not submitted: the peer pane shows no live composer; read the pane before any resend"
UNSUBMITTED_NO_TEXT="peer-chat-paste: pasted, not submitted: the composer does not hold the message; read the pane before any resend"
HELD_NOTICE="notify message for right held: the peer shows a dialog --title peer-chat"

dialog_before_paste() { # dialog_before_paste <fixture> <reads it stays for>
    cp "${FIX}/$1" "${TMP}/dialog"
    echo "$2" > "${TMP}/dialog-reads"
}

dialog_from_read() { # dialog_from_read <fixture> <first read after the paste it covers> <reads it stays for>
    cp "${FIX}/$1" "${TMP}/dialog"
    echo "$2" > "${TMP}/dialog-from"
    echo $(($2 + $3)) > "${TMP}/dialog-until"
}

# The first pasted read confirms the paste; the dialog covers the reads after it.
dialog_after_paste() { dialog_from_read "$1" 1 "$2"; }

claude_peer() {
    cp "${FIX}/tree-pair-claude-claude.json" "${TMP}/tree.json"
    printf '❯ \n' > "${TMP}/composer"
}

logged_calls() { touch "${TMP}/calls.log"; grep -c "^$1 " "${TMP}/calls.log" || true; }
paste_calls() { awk 'END { print NR }' "${TMP}/paste-calls.log"; }
notify_calls() { logged_calls notify; }
message_states() { jq -r '[.messages[].state] | join(",")' "${TMP}/${LEDGER}"; }

nothing_recorded() {
    [ ! -f "${TMP}/${LEDGER}" ] || jq -e '(.messages | length) == 0 and (.asks | length) == 0' "${TMP}/${LEDGER}"
}

hold_lock() { # hold_lock <lock file> <seconds> — returns once the lock is held
    local held="${TMP}/held.${RANDOM}"
    mkdir -p "$(dirname "$1")"
    python3 - "$1" "$2" "${held}" <<'PY' &
import fcntl, sys, time
from pathlib import Path
with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    Path(sys.argv[3]).touch()
    time.sleep(float(sys.argv[2]))
PY
    HOLDER=$!
    while [ ! -f "${held}" ]; do sleep 0.05; done
}

@test "gate: a Claude question dialog holds the send, which lands once when the dialog closes" {
    claude_peer
    dialog_before_paste claude-dialog-askuserquestion.txt 3
    printf '🎯 the answer\n\n🔎 path.go:12\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 20s
    assert_status 0
    assert_not_contains "${output}" "held"
    [ "$(paste_calls)" = 1 ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ "$(notify_calls)" = 0 ]
}

@test "gate: a Codex approval modal that outlasts the budget exits 2 with nothing prepared, pasted or typed" {
    dialog_before_paste codex-approval-modal.txt 9999
    printf '🔎 Processor.php:23\n\n❓ does a retry create a second bid?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 2
    assert_contains "${output}" "${HELD_NO_COMPOSER}"
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/typed.log" ]
    [ ! -f "${TMP}/pasted-first" ]
    nothing_recorded

    echo 0 > "${TMP}/dialog-reads"
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 0
    assert_contains "$(cat "${TMP}/pasted-first")" "❓ #left-001 does a retry create a second bid?"
    [ "$(message_states)" = submit_sent ]
}

@test "gate: a send without --slug is held the same way" {
    dialog_before_paste codex-approval-modal.txt 9999
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s
    assert_status 2
    assert_contains "${output}" "${HELD_NO_COMPOSER}"
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/typed.log" ]
}

@test "gate: a working Codex with a readable composer is not held" {
    cp "${FIX}/codex-working-composer.txt" "${TMP}/composer"
    printf '🎯 a steer\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s
    assert_status 0
    assert_contains "${output}" "the peer is mid-turn"
    [ "$(paste_calls)" = 1 ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "gate: a Codex composer holding a message with blank lines still gets its Return" {
    printf '  Worked for 54s • 23:43\n\n› Ask Codex to do anything\n\n  gpt high · repo · Context 28%% used\n' > "${TMP}/composer"
    printf '🎯 the guard is blind\n\n🔎 Processor.php:23\n\n🎯 on your side of the flow too\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s
    assert_status 0
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "gate: a tail that a narrow pane wrapped inside the composer still gets its Return" {
    claude_peer
    printf '%s\n' '────────────────────────────────' '❯ Chat from claude (left): 🎯 it happens on your side of' '  the flow too' '────────────────────────────────' '  ? for shortcuts' > "${TMP}/pasted-screen"
    printf '🎯 it happens on your side of the flow too\n' > "${TMP}/msg"
    PEER_CHAT_WRAP=0 send_file "${TMP}/msg" --wait 1s
    assert_status 0
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "gate: an unknown composer rendering is held, and PEER_CHAT_COMPOSER_GATE=off sends as before" {
    printf 'unrecognized composer rendering\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s
    assert_status 2
    assert_contains "${output}" "${HELD_NO_COMPOSER}"
    assert_not_contains "${output}" "PEER_CHAT_COMPOSER_GATE"
    [ "$(paste_calls)" = 0 ]

    PEER_CHAT_COMPOSER_GATE=off send_file "${TMP}/msg" --wait 1s
    assert_status 0
    assert_contains "${output}" "${GATE_OFF}"
    [ "$(paste_calls)" = 1 ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "gate: a dialog that opens after the paste holds Return until a composer with the paste marker is back" {
    claude_peer
    dialog_after_paste claude-dialog-askuserquestion.txt 3
    claude_composer "${TMP}/pasted-screen" '[Pasted text #1 +3 lines]'
    echo 4 > "${TMP}/pasted-screen-from"
    printf '🎯 one\n\n🔎 two\n\n🎯 three\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 20s
    assert_status 0
    [ "$(paste_calls)" = 1 ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ "$(message_states)" = submit_sent ]
    [ "$(notify_calls)" = 0 ]
}

@test "gate: a composer that comes back without the message exits 1 at once, with no Return and no notice" {
    printf 'Chat from claude (left): 🎯 lost in a dialog\n\n› Ask Codex to do anything\n\n  gpt high · repo\n' > "${TMP}/pasted-screen"
    echo 1 > "${TMP}/pasted-screen-from"
    printf '🎯 lost in a dialog\n' > "${TMP}/msg"
    SECONDS=0
    send_file "${TMP}/msg" --slug seatos --wait 60s
    assert_status 1
    [ "${SECONDS}" -lt 20 ]
    assert_contains "${output}" "${UNSUBMITTED_NO_TEXT}"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(message_states)" = uncertain ]
    [ "$(notify_calls)" = 0 ]
}

@test "gate: PEER_CHAT_COMPOSER_GATE=off presses Return without reading the composer after the paste" {
    printf 'Chat from claude (left): 🎯 as before\n\n› Ask Codex to do anything\n\n  gpt high · repo\n' > "${TMP}/pasted-screen"
    echo 1 > "${TMP}/pasted-screen-from"
    printf '🎯 as before\n' > "${TMP}/msg"
    PEER_CHAT_COMPOSER_GATE=off send_file "${TMP}/msg" --slug seatos
    assert_status 0
    assert_contains "${output}" "${GATE_OFF}"
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ "$(message_states)" = submit_sent ]
}

@test "gate: a dialog that outlasts the budget after the paste exits 1, uncertain, with one notice" {
    dialog_after_paste codex-approval-modal.txt 9999
    printf '🎯 pasted then covered\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 1
    assert_contains "${output}" "${UNSUBMITTED_NO_COMPOSER}"
    [ "$(paste_calls)" = 1 ]
    [ ! -f "${TMP}/typed.log" ]
    [ "$(message_states)" = uncertain ]
    [ "$(notify_calls)" = 1 ]
    assert_contains "$(cat "${TMP}/calls.log")" "${HELD_NOTICE}"
}

@test "notify: a held send notifies once, --no-notify stays silent, a failed notice keeps exit 2" {
    dialog_before_paste codex-approval-modal.txt 9999
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s
    assert_status 2
    [ "$(notify_calls)" = 1 ]
    assert_contains "$(cat "${TMP}/calls.log")" "${HELD_NOTICE}"

    : > "${TMP}/calls.log"
    send_file "${TMP}/msg" --wait 1s --no-notify
    assert_status 2
    [ "$(notify_calls)" = 0 ]

    touch "${TMP}/notify-fails"
    send_file "${TMP}/msg" --wait 1s
    assert_status 2
    assert_contains "${output}" "${HELD_NO_COMPOSER}"
}

@test "lock: a send behind a waiting send exits 2 inside the lock wait, with nothing recorded or typed" {
    hold_lock "${TMP}/tmp/peer-chat/seatos/outbox-${SID}-right.delivery.lock" 5
    printf '❓ x?\n' > "${TMP}/msg"
    SECONDS=0
    send_file "${TMP}/msg" --slug seatos
    kill "${HOLDER}"
    assert_status 2
    [ "${SECONDS}" -lt 4 ]
    assert_contains "${output}" "${HELD_LOCK}"
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/typed.log" ]
    nothing_recorded
    [ "$(notify_calls)" = 0 ]
}

@test "lock: a send whose lock frees inside the lock wait goes through" {
    hold_lock "${TMP}/tmp/peer-chat/seatos/outbox-${SID}-right.delivery.lock" 0.3
    printf '🎯 x\n' > "${TMP}/msg"
    PEER_CHAT_LOCK_WAIT=5 send_file "${TMP}/msg" --slug seatos
    wait "${HOLDER}"
    assert_status 0
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "recover: a transport lock held past the lock wait exits 2 and presses nothing" {
    recorded_outbox
    recorded_composer "${TMP}/composer"
    hold_lock "${TMP}/tmp/peer-chat/t/outbox-${SID}-left.delivery.lock" 5
    recover
    kill "${HOLDER}"
    assert_status 2
    assert_contains "${output}" "${HELD_LOCK}"
    [ ! -f "${TMP}/typed.log" ]
    [ -f "$(outbox left.msg)" ]
}

@test "budget: --wait beats PEER_CHAT_DELIVERY_WAIT, which beats delivery_wait_minutes, which beats 60 s" {
    printf '🎯 x\n' > "${TMP}/msg"
    printf '{"delivery_wait_minutes":0.005}\n' > "${TMP}/.peer-chat.json"
    dialog_before_paste codex-approval-modal.txt 9999
    SECONDS=0
    send_file "${TMP}/msg" --slug seatos --no-notify
    assert_status 2
    [ "${SECONDS}" -lt 20 ]

    dialog_before_paste codex-approval-modal.txt 8
    PEER_CHAT_DELIVERY_WAIT=0.5 send_file "${TMP}/msg" --slug seatos --no-notify
    assert_status 0

    printf 'empty' > "${TMP}/state"
    dialog_before_paste codex-approval-modal.txt 9999
    SECONDS=0
    PEER_CHAT_DELIVERY_WAIT=0.5 send_file "${TMP}/msg" --slug seatos --no-notify --wait 0.3s
    assert_status 2
    [ "${SECONDS}" -lt 20 ]
}

@test "budget: a zero or unitless --wait is a usage error before any paste" {
    printf '🎯 x\n' > "${TMP}/msg"
    for value in 0s 30 -5s soon "$(printf '1%.0s' {1..400})s"; do
        send_file "${TMP}/msg" --wait "${value}"
        assert_status 2
    done
    [ "$(paste_calls)" = 0 ]
}

@test "budget: a zero, negative or non-numeric env or config value exits 2 before any paste" {
    printf '🎯 x\n' > "${TMP}/msg"
    PEER_CHAT_DELIVERY_WAIT=0 send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "peer-chat-paste: PEER_CHAT_DELIVERY_WAIT must be a positive number, got '0'"
    PEER_CHAT_DELIVERY_POLL=abc send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "PEER_CHAT_DELIVERY_POLL must be a positive number, got 'abc'"
    PEER_CHAT_LOCK_WAIT=-1 send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "PEER_CHAT_LOCK_WAIT must be a positive number, got '-1'"
    printf '{"delivery_wait_minutes":"soon"}\n' > "${TMP}/.peer-chat.json"
    send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "delivery_wait_minutes must be a positive number, got 'soon'"
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/typed.log" ]
    nothing_recorded
}

@test "gate: a Codex draft with a blank line in the composer does not hold the send" {
    printf '• Done\n\n› first paragraph of a draft\n\n  second paragraph\n\n  gpt high · repo\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s
    assert_status 0
    [ "$(paste_calls)" = 1 ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "gate: a numbered Codex overlay under an old user message holds the send" {
    printf '› run the tests\n\n  Select a model\n\n  1. gpt high\n  2. gpt low\n\n  Press enter to confirm or esc to cancel\n' > "${TMP}/composer"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s --no-notify
    assert_status 2
    assert_contains "${output}" "${HELD_NO_COMPOSER}"
    [ "$(paste_calls)" = 0 ]
}

@test "gate: a message with a numbered list still gets its Return from a Codex composer" {
    printf '  Worked for 54s • 23:43\n\n› Ask Codex to do anything\n\n  gpt high · repo\n' > "${TMP}/composer"
    printf '🎯 two steps\n\n1. read the pane\n2. rerun the send\n\n🎯 then report\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --wait 1s
    assert_status 0
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

@test "spool: a held --message-file send restores the spool, and the rerun delivers and consumes it" {
    export TMPDIR="${TMP}"
    python3 "${PLUGIN}/scripts/peer-chat.py" --prepare-message peer-chat-held-a91f.txt >/dev/null
    spool="$(ls -d "${TMP}"/agterm-peer-chat-*)/peer-chat-held-a91f.txt"
    printf '🎯 held behind a dialog\n' > "${spool}"
    dialog_before_paste codex-approval-modal.txt 9999
    run python3 "${PASTE}" --to codex --message-file peer-chat-held-a91f.txt --slug seatos --wait 1s
    assert_status 2
    assert_contains "${output}" "${HELD_NO_COMPOSER}"
    assert_contains "${output}" "message file restored: peer-chat-held-a91f.txt"
    [ "$(cat "${spool}")" = '🎯 held behind a dialog' ]

    echo 0 > "${TMP}/dialog-reads"
    run python3 "${PASTE}" --to codex --message-file peer-chat-held-a91f.txt --slug seatos --wait 1s
    assert_status 0
    [ ! -e "${spool}" ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

# ------------------------------------- whole-message probe, second read --

PASTE_UNCONFIRMED="paste not confirmed in the composer; read the pane before any resend"
LOCK_SYMLINK="peer-chat-paste: delivery lock path is a symlink; inspect it before any send"
CODEX_IDLE='  Worked for 54s • 23:43'
CODEX_FOOTER='  gpt high · repo · Context 28% used'

key_read() { cat "${TMP}/typed-at-read"; }

@test "probe: a last line an older message in the pane also ends with does not confirm the paste" {
    printf '  Chat from claude (left): 🎯 the first build is green\n\n  🎯 done\n\n%s\n\n› Ask Codex to do anything\n\n%s\n' "${CODEX_IDLE}" "${CODEX_FOOTER}" > "${TMP}/composer"
    touch "${TMP}/paste-ignored"
    printf '🎯 the second build is green\n\n🎯 done\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 1
    assert_contains "${output}" "${PASTE_UNCONFIRMED}"
    assert_not_contains "${output}" "pasted, not submitted"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(message_states)" = uncertain ]
}

@test "probe: a composer holding other text that ends in the same last line gets no Return" {
    printf '%s\n\n› an older draft about the first build\n\n  🎯 done\n\n%s\n' "${CODEX_IDLE}" "${CODEX_FOOTER}" > "${TMP}/pasted-screen"
    echo 1 > "${TMP}/pasted-screen-from"
    printf '🎯 the second build is green\n\n🎯 done\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 1
    assert_contains "${output}" "${UNSUBMITTED_NO_TEXT}"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(message_states)" = uncertain ]
}

@test "second read: a dialog on the read right before the key gets no Return, and the message lands once when the composer is back" {
    claude_peer
    dialog_from_read claude-dialog-askuserquestion.txt 2 3
    printf '🎯 one\n\n🔎 two\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 20s
    assert_status 0
    [ "$(paste_calls)" = 1 ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ "$(key_read)" -ge 7 ]
    [ "$(message_states)" = submit_sent ]
    [ "$(notify_calls)" = 0 ]
}

@test "second read: --queue reads the composer again after it picked the key" {
    codex_working_screen
    dialog_from_read codex-approval-modal.txt 3 3
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --queue --slug seatos --wait 20s
    assert_status 0
    [ "$(typed_keys)" = '\t' ]
    [ "$(key_read)" -ge 6 ]
    [ "$(message_states)" = submit_sent ]
}

@test "second read: --queue picks the key again when the dialog closed over a finished turn" {
    codex_working_screen
    dialog_from_read codex-approval-modal.txt 3 3
    printf '%s\n\n› Chat from claude (left): 🎯 the background check finished\n' "${CODEX_IDLE}" > "${TMP}/pasted-screen"
    echo 6 > "${TMP}/pasted-screen-from"
    printf '🎯 the background check finished\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --queue --slug seatos --wait 20s
    assert_status 0
    [ "$(typed_keys)" = '\n' ]
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
}

# ------------------------------------------------------ lock path symlink --

symlinked_lock() { # symlinked_lock <topic> <pane> <target>
    mkdir -p "${TMP}/tmp/peer-chat/$1"
    ln -s "$3" "${TMP}/tmp/peer-chat/$1/outbox-${SID}-$2.delivery.lock"
}

@test "lock: a symlink at the lock path exits 2 with nothing typed or recorded, and its target is left alone" {
    symlinked_lock seatos right "${TMP}/elsewhere"
    printf '❓ x?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "${LOCK_SYMLINK}"
    [ ! -e "${TMP}/elsewhere" ]
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/typed.log" ]
    nothing_recorded
    [ "$(notify_calls)" = 0 ]

    printf 'kept' > "${TMP}/elsewhere"
    send_file "${TMP}/msg" --slug seatos
    assert_status 2
    assert_contains "${output}" "${LOCK_SYMLINK}"
    [ "$(cat "${TMP}/elsewhere")" = kept ]
    [ "$(paste_calls)" = 0 ]
}

@test "recover: a symlink at the lock path exits 2 and presses nothing" {
    recorded_outbox
    recorded_composer "${TMP}/composer"
    symlinked_lock t left "${TMP}/elsewhere"
    recover
    assert_status 2
    assert_contains "${output}" "${LOCK_SYMLINK}"
    [ ! -e "${TMP}/elsewhere" ]
    [ ! -f "${TMP}/typed.log" ]
    [ -f "$(outbox left.msg)" ]
}

# ------------------------------------------------- real Codex choosers --

chooser_holds_send() { # chooser_holds_send <fixture>
    dialog_before_paste "$1" 9999
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 2
    assert_contains "${output}" "${HELD_NO_COMPOSER}"
    [ "$(paste_calls)" = 0 ]
    [ ! -f "${TMP}/typed.log" ]
    nothing_recorded
}

@test "gate: the Codex folder-trust chooser, captured live, holds the send" {
    chooser_holds_send codex-trust-chooser.txt
}

@test "gate: the Codex hooks-review chooser, captured live, holds the send" {
    chooser_holds_send codex-hooks-chooser.txt
}

@test "gate: the Codex hooks-review chooser opening after the paste gets no Return" {
    dialog_after_paste codex-hooks-chooser.txt 9999
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 1
    assert_contains "${output}" "${UNSUBMITTED_NO_COMPOSER}"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(message_states)" = uncertain ]
    [ "$(notify_calls)" = 1 ]
}

@test "second read: a message gone from a live composer between the two reads exits 1 at once, with no Return and no notice" {
    printf '%s\n\n› Ask Codex to do anything\n\n%s\n' "${CODEX_IDLE}" "${CODEX_FOOTER}" > "${TMP}/pasted-screen"
    echo 2 > "${TMP}/pasted-screen-from"
    printf '🎯 gone between the two reads\n' > "${TMP}/msg"
    SECONDS=0
    PEER_CHAT_DELIVERY_POLL=30 send_file "${TMP}/msg" --slug seatos --wait 60s
    assert_status 1
    [ "${SECONDS}" -lt 20 ]
    assert_contains "${output}" "${UNSUBMITTED_NO_TEXT}"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(message_states)" = uncertain ]
    [ "$(notify_calls)" = 0 ]
}

@test "second read: a pane that shows the message on every first read and a dialog on every second one exits 1 when the budget runs out" {
    claude_peer
    cp "${FIX}/claude-dialog-askuserquestion.txt" "${TMP}/dialog"
    touch "${TMP}/dialog-on-even-reads"
    printf '🎯 one\n\n🔎 two\n' > "${TMP}/msg"
    SECONDS=0
    send_file "${TMP}/msg" --slug seatos --wait 1s
    assert_status 1
    [ "${SECONDS}" -lt 15 ]
    assert_contains "${output}" "${UNSUBMITTED_NO_COMPOSER}"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(message_states)" = uncertain ]
    [ "$(notify_calls)" = 1 ]
}
