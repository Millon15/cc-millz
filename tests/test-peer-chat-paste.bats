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
    export AGTERM_SESSION_ID="${SID}" PEER_CHAT_TRANSPORT="${PLUGIN}/scripts/peer-chat.py"
    export PEER_CHAT_PASTE_TIMEOUT=1 PEER_CHAT_ACCEPT_TIMEOUT=1
    unset AGTERM_WINDOW_ID
    printf 'user clipboard' > "${TMP}/clip"
    printf 'empty' > "${TMP}/state"
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
    "tree --json") cat "${FIX}/tree-split-codex.json" ;;
    "surface cursor") [ ! -f "${TMP}/cursor-unavailable" ] || exit 9; echo 2 ;;
    "session text")
        case "\$state" in
            pasted) cat "${TMP}/clip-last-set"; echo; cat "${TMP}/composer" 2>/dev/null || cat "${FIX}/codex-pane-empty.txt" ;;
            busy) printf '› half a line the user typed\n \n  footer row\n' ;;
            submitted) cat "${TMP}/after-submit" 2>/dev/null || cat "${FIX}/codex-pane-empty.txt" ;;
            *) cat "${TMP}/composer" 2>/dev/null || cat "${FIX}/codex-pane-empty.txt" ;;
        esac ;;
    "session paste") [ -f "${TMP}/paste-ignored" ] || printf 'pasted' > "${TMP}/state"; echo ok ;;
    "session type") cat >> "${TMP}/typed.log"; printf 'submitted' > "${TMP}/state"; echo ok ;;
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
    local target="$1" prompt pane state after expected_label
    if [ "$target" = claude ]; then
        prompt='❯'; pane=left; expected_label='Chat from Codex:'
    else
        prompt='›'; pane=right; expected_label='Chat from Claude:'
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
            run python3 "${PASTE}" --to "$target" --stdin < "${TMP}/msg"
            assert_status 0
            assert_contains "$(cat "${TMP}/clip-last-set")" "$expected_label"
            assert_contains "$(cat "${TMP}/calls.log")" "session paste --pane ${pane} --target ${SID}"
            [ "$(wc -l < "${TMP}/typed.log")" -eq 1 ]
            [ "$(cat "${TMP}/clip")" = "user clipboard" ]
            assert_not_contains "$(cat "${TMP}/calls.log")" 'surface cursor'
            assert_not_contains "$output" 'composer is not empty'
            assert_not_contains "$output" 'composer did not clear'
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

LEDGER="tmp/peer-chat/seatos/asks.tsv"

seed_codex_ask() { # seed_codex_ask <disposition> <due> <reason>
    mkdir -p "${TMP}/tmp/peer-chat/seatos"
    printf 'id\tasked_by\tsent_at\tdisposition\tdue\treason\tquestion\n' > "${TMP}/${LEDGER}"
    printf 'codex-001\tcodex\t2026-09-10T08:00:00Z\t%s\t%s\t%s\tdoes the refund path reuse the bid?\n' "$1" "$2" "$3" >> "${TMP}/${LEDGER}"
}

@test "ledger: --slug issues a topic-scoped id to every ❓, writes the row after delivery, reports it" {
    printf '🔎 Processor.php:23\n\n❓ does a retry create a second bid?\n\n❓ is the 409 retried at all?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    pasted="$(cat "${TMP}/clip-first-set")"
    assert_contains "${pasted}" "❓ #claude-001 does a retry create a second bid?"
    assert_contains "${pasted}" "❓ #claude-002 is the 409 retried at all?"
    assert_contains "${output}" '"asks": ["#claude-001", "#claude-002"]'
    assert_contains "$(cat "${TMP}/${LEDGER}")" $'claude-001\tclaude\t'
    assert_contains "$(cat "${TMP}/${LEDGER}")" $'\t\t\t\tdoes a retry create a second bid?'
    assert_not_contains "${output}" "no --slug"
}

@test "ledger: a failed delivery records nothing" {
    touch "${TMP}/paste-ignored"
    printf '❓ x?\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 1
    [ ! -f "${TMP}/${LEDGER}" ]
}

@test "ledger: a new ask from the peer with no disposition refuses the send before anything is written" {
    seed_codex_ask "" "" ""
    printf '🎯 the guard is blind across bids\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 1
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
    assert_contains "$(cat "${TMP}/${LEDGER}")" $'codex-001\tcodex\t2026-09-10T08:00:00Z\tanswered\t\tno, the refund path opens a new bid\t'
}

@test "ledger: deferred keeps the ask open with a due time, and the next send is not refused" {
    seed_codex_ask "" "" ""
    printf '#codex-001 deferred(after the fixture run)\n' > "${TMP}/msg"
    send_file "${TMP}/msg" --slug seatos
    assert_status 0
    row="$(grep '^codex-001' "${TMP}/${LEDGER}")"
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
    [ "$(head -1 "${TMP}/clip-first-set")" = "Chat from Claude: overdue: #codex-001 deferred(after the fixture" ]
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
    assert_status 1
    assert_contains "${output}" "message file restored: peer-chat-codex-a91f.txt"
    [ "$(cat "${spool}/peer-chat-codex-a91f.txt")" = "🎯 the guard is blind across bids" ]
}
