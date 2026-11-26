#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/tests/helpers/common.bash"
    setup_tmp
    FREEZE="${REPO_ROOT}/plugins/peer-chat/scripts/peer-chat-freeze.py"
    FRESH="${REPO_ROOT}/plugins/peer-chat/scripts/peer-chat-fresh.sh"
    REPO="${TMP}/repo"
    mkdir -p "${REPO}"
    git -C "${REPO}" init -q
    printf '/tmp/\n' >"${REPO}/.gitignore"
    printf 'one\n' >"${REPO}/a.txt"
    printf 'one\n' >"${REPO}/b.txt"
    git -C "${REPO}" add .
    git -C "${REPO}" -c user.name=T -c user.email=t@example.invalid commit -qm fixture
}

teardown() { teardown_tmp; }

freeze() { (cd "${REPO}" && python3 "${FREEZE}" --slug topic "$@"); }

@test "freeze: tree holds tracked edits and untracked files, real index untouched" {
    printf 'two\n' >"${REPO}/a.txt"
    printf 'new\n' >"${REPO}/c.txt"
    run freeze
    [ "${status}" -eq 0 ]
    tree="$(jq -r .tree <<<"${output}")"
    head="$(git -C "${REPO}" rev-parse HEAD)"
    [ "$(jq -r .previous <<<"${output}")" = "${head}" ]
    [ "$(git -C "${REPO}" diff --name-only "${head}" "${tree}" | tr '\n' ' ')" = "a.txt c.txt " ]
    [ -z "$(git -C "${REPO}" diff --cached --name-only)" ]
    [ "$(git -C "${REPO}" status --porcelain | tr '\n' ' ')" = " M a.txt ?? c.txt " ]
}

@test "freeze: a re-freeze diffs against the previous tree only" {
    printf 'two\n' >"${REPO}/a.txt"
    first="$(freeze | jq -r .tree)"
    printf 'two\n' >"${REPO}/b.txt"
    run freeze
    [ "$(jq -r .previous <<<"${output}")" = "${first}" ]
    [ "$(jq -r .freeze <<<"${output}")" = "2" ]
    [ "$(jq -r .diff <<<"${output}")" = "git diff ${first} $(jq -r .tree <<<"${output}")" ]
    [ "$(git -C "${REPO}" diff --name-only "${first}" "$(jq -r .tree <<<"${output}")")" = "b.txt" ]
    [ "$(jq '.freezes | length' "${REPO}/tmp/peer-chat/topic/state.json")" = "2" ]
}

@test "freeze: a coordinator shared by two repositories keeps each previous tree separate" {
    first="$(freeze | jq -r .tree)"
    state="${REPO}/tmp/peer-chat/topic/state.json"
    OTHER="${TMP}/other"
    git init -q "${OTHER}"
    printf 'different\n' >"${OTHER}/own.txt"
    git -C "${OTHER}" add .
    git -C "${OTHER}" -c user.name=T -c user.email=t@example.invalid commit -qm other
    other_head="$(git -C "${OTHER}" rev-parse HEAD)"
    run bash -c 'cd "$1"; python3 "$2" --slug topic --state "$3"' _ "${OTHER}" "${FREEZE}" "${state}"
    assert_status 0
    [ "$(jq -r .previous <<<"${output}")" = "${other_head}" ]
    printf 'two\n' >"${REPO}/a.txt"
    run freeze
    assert_status 0
    [ "$(jq -r .previous <<<"${output}")" = "${first}" ]
    [ "$(jq '.freezes | length' "${state}")" = 3 ]
    [ ! -f "${OTHER}/tmp/peer-chat/topic/state.json" ]
}

@test "freeze: pathspecs keep the other lane's edits out of the tree" {
    printf 'two\n' >"${REPO}/a.txt"
    printf 'two\n' >"${REPO}/b.txt"
    run freeze -- a.txt
    [ "${status}" -eq 0 ]
    [ "$(git -C "${REPO}" diff --name-only HEAD "$(jq -r .tree <<<"${output}")")" = "a.txt" ]
}

@test "freeze: a same-size edit the index holds as racily clean lands in the tree" {
    git -C "${REPO}" config core.trustctime false
    touch -t 202001010000 "${REPO}/a.txt"
    git -C "${REPO}" update-index --refresh
    printf 'two\n' >"${REPO}/a.txt"
    touch -t 202001010000 "${REPO}/a.txt" "${REPO}/.git/index"
    [ "$(git -C "${REPO}" diff --name-only)" = "a.txt" ]
    run freeze
    [ "${status}" -eq 0 ]
    [ "$(git -C "${REPO}" diff --name-only HEAD "$(jq -r .tree <<<"${output}")")" = "a.txt" ]
}

@test "fresh: usage error without --focus and --resume" {
    run bash "${FRESH}"
    [ "${status}" -eq 2 ]
}

@test "fresh: exit 3 outside agterm or without a Claude Code session id" {
    AGTERM_SESSION_ID='' CLAUDE_CODE_SESSION_ID='' run bash "${FRESH}" --focus f --resume r
    [ "${status}" -eq 3 ]
    assert_contains "${output}" "print both lines for the user"
}

@test "fresh: submits each line with a separate Return keystroke" {
    body="$(cat "${FRESH}")"
    assert_contains "$body" 'type_line "type $1" "$2"'
    assert_contains "$body" "type_line \"submit \$1\" \$'\\n'"
}

run_fresh_watcher() {
    export FRESH_TEST_FAILURE="$1" FRESH_TEST_TRANSCRIPT="$TMP/claude/projects/p/probe-session.jsonl"
    mkdir -p "$TMP/claude/projects/p"
    : > "$FRESH_TEST_TRANSCRIPT"
    stub sleep
    stub agtermctl '
        case "$1 $2" in
            "session text")
                printf "read\n" >> "$TMP/agterm-reads"
                if [ "$FRESH_TEST_FAILURE" != read ]; then printf "❯ \n"; exit 0; fi ;;
            "session type")
                printf "%q\n" "$7" >> "$TMP/agterm-writes"
                if [ "$7" != "resume me" ]; then
                    printf "{\"subtype\":\"compact_boundary\"}\n" >> "$FRESH_TEST_TRANSCRIPT"
                    exit 0
                fi ;;
        esac
        echo "error: unknown pane id" >&2
        exit 1
    '
    TMPDIR="$TMP" CLAUDE_CONFIG_DIR="$TMP/claude" AGTERM_SOCKET= \
        run bash "$FRESH" --foreground --focus f --resume "resume me" \
        --session S1 --pane-id gone-token --claude-session probe-session
}

@test "fresh: a failed pane read logs the step and stops without retrying or typing" {
    run_fresh_watcher read
    assert_status 1
    grep -q 'could not read pane before /compact: error: unknown pane id' "$TMP/peer-chat-fresh.probe-session.log"
    [ "$(wc -l < "$TMP/agterm-reads")" -eq 1 ]
    [ ! -f "$TMP/agterm-writes" ]
}

@test "fresh: a failed resume write logs the step and sends no further Return" {
    run_fresh_watcher resume
    assert_status 1
    grep -q 'could not type the resume line: error: unknown pane id' "$TMP/peer-chat-fresh.probe-session.log"
    [ "$(wc -l < "$TMP/agterm-writes")" -eq 3 ]
    [ "$(tail -1 "$TMP/agterm-writes")" = "$(printf '%q' "resume me")" ]
}
