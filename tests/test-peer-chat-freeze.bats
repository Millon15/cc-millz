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
    [ "$(wc -l <"${REPO}/tmp/peer-chat/topic/freezes.tsv" | tr -d ' ')" = "2" ]
}

@test "freeze: pathspecs keep the other lane's edits out of the tree" {
    printf 'two\n' >"${REPO}/a.txt"
    printf 'two\n' >"${REPO}/b.txt"
    run freeze -- a.txt
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
    assert_contains "${body}" "pane \"\$pane\" \"\$1\" >/dev/null"
    assert_contains "${body}" "pane \"\$pane\" \$'\\n' >/dev/null"
}
