#!/usr/bin/env bats
#
# tests/test-peer-chat-paste.bats
#
# peer-chat-paste.py loads the vendored transport as a module and drives agterm through it, so
# the suite stubs agtermctl with a state machine (empty composer, pasted, submitted) and pbcopy /
# pbpaste with a clipboard file. The assertions read what was pasted (the label, the preserved
# line breaks), the single submit keystroke, the clipboard restore, and the refusals: a busy
# composer gets nothing, an unconfirmed paste gets no submit.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="${REPO_ROOT}/plugins/peer-chat"
    PASTE="${PLUGIN}/scripts/peer-chat-paste.py"
    FIX="${REPO_ROOT}/tests/fixtures/peer-chat"
    SID="11111111-1111-1111-1111-111111111111"
    export AGTERM_SESSION_ID="${SID}" PEER_CHAT_TRANSPORT="${PLUGIN}/scripts/peer-chat.py"
    export PEER_CHAT_PASTE_TIMEOUT=1 PEER_CHAT_ACCEPT_TIMEOUT=1
    unset AGTERM_WINDOW_ID
    printf 'user clipboard' > "${TMP}/clip"
    printf 'empty' > "${TMP}/state"
    stub pbcopy "cat > '${TMP}/clip'; [ -f '${TMP}/clip-first-set' ] || cp '${TMP}/clip' '${TMP}/clip-first-set'"
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
    "tree --json") cat "${FIX}/tree-split-codex.json" ;;
    "surface cursor") echo 2 ;;
    "session text")
        case "\$state" in
            pasted) cat "${TMP}/clip-first-set"; echo; cat "${FIX}/codex-pane-empty.txt" ;;
            busy) printf '› half a line the user typed\n \n  footer row\n' ;;
            *) cat "${FIX}/codex-pane-empty.txt" ;;
        esac ;;
    "session paste") [ -f "${TMP}/paste-ignored" ] || printf 'pasted' > "${TMP}/state"; echo ok ;;
    "session type") cat >> "${TMP}/typed.log"; printf 'empty' > "${TMP}/state"; echo ok ;;
    *) echo "stub: unexpected \$*" >&2; exit 9 ;;
esac
EOF
    chmod +x "${STUB_BIN}/agtermctl"
}

send_file() { # send_file <message-file> [extra args]
    local file="$1"
    shift
    run python3 "${PASTE}" --to codex --stdin "$@" < "${file}"
}

@test "paste: a multi-line body is pasted with the label, submitted once, and the clipboard is restored" {
    printf '🎯 the guard is blind across bids\n\n🔎 DoublePaymentProcessor.php:23-31\n\n❓ does a retry create a second bid?\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    assert_contains "${output}" '"lines": 5'
    [ "$(head -1 "${TMP}/clip-first-set")" = "Chat from Claude: 🎯 the guard is blind across bids" ]
    [ "$(tail -1 "${TMP}/clip-first-set")" = "❓ does a retry create a second bid?" ]
    assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane right --target ${SID}"
    [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
}

@test "paste: an existing label is not doubled and trailing blank lines are dropped" {
    printf 'Chat from Claude: 🎯 one line\n\n\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 0
    [ "$(cat "${TMP}/clip-first-set")" = "Chat from Claude: 🎯 one line" ]
}

@test "paste: a composer that is not empty is refused before anything is written" {
    printf 'busy' > "${TMP}/state"
    printf '🎯 x\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "composer is not empty"
    assert_not_contains "$(cat "${TMP}/calls.log")" "session paste"
    [ ! -f "${TMP}/typed.log" ]
    [ "$(cat "${TMP}/clip")" = "user clipboard" ]
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

@test "paste: a control character other than newline is refused" {
    printf '🎯 x\ty\n' > "${TMP}/msg"
    send_file "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "control character"
}

@test "paste: exit 1 naming peer-chat.py when the transport is not on PATH" {
    unset PEER_CHAT_TRANSPORT
    printf '🎯 x\n' > "${TMP}/msg"
    PATH="${STUB_BIN}:/usr/bin:/bin" run python3 "${PASTE}" --to codex --stdin < "${TMP}/msg"
    assert_status 1
    assert_contains "${output}" "peer-chat.py not on PATH"
}
