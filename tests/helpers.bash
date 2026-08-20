# tests/helpers.bash — shared bats helpers for every plugin suite.
#
# Source it from a suite's setup():
#
#     setup() {
#         REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
#         source "${REPO_ROOT}/tests/helpers.bash"
#         setup_tmp
#     }
#     teardown() { teardown_tmp; }
#
# Requires bats-core. `assert_explain_source` requires jq.

# ---------------------------------------------------------------- temp dirs --

# Creates $TMP (a fresh temp directory) and $STUB_BIN, prepended to PATH so a
# suite can shadow any executable the code under test shells out to.
setup_tmp() {
    TMP="$(mktemp -d)"
    STUB_BIN="${TMP}/stub-bin"
    mkdir -p "${STUB_BIN}"
    PATH="${STUB_BIN}:${PATH}"
    export TMP STUB_BIN PATH
}

teardown_tmp() {
    [ -n "${TMP:-}" ] && [ -d "${TMP}" ] && rm -rf "${TMP}"
    return 0
}

# ------------------------------------------------------------------- stubs --

# stub <name> <body...> — writes an executable stub on PATH. Without a body the
# stub succeeds silently, which is enough to make a `command -v` probe pass.
stub() {
    local name="$1"
    shift
    {
        printf '#!/usr/bin/env bash\n'
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$*"
        else
            printf 'exit 0\n'
        fi
    } >"${STUB_BIN}/${name}"
    chmod +x "${STUB_BIN}/${name}"
}

# unstub <name> — removes a stub so the real executable (or its absence) shows.
unstub() {
    rm -f "${STUB_BIN}/$1"
}

# ------------------------------------------------------------ git fixtures --

# make_git_repo <path> — an initialised repo with a local identity, signing off
# and hooks disabled, so a fixture never picks up the developer's global config.
make_git_repo() {
    local dir="$1" hooks="${TMP}/no-hooks"
    mkdir -p "${dir}" "${hooks}"
    git -C "${dir}" init -q
    git -C "${dir}" config user.email t@example.invalid
    git -C "${dir}" config user.name t
    git -C "${dir}" config commit.gpgsign false
    git -C "${dir}" config core.hooksPath "${hooks}"
}

# ----------------------------------------------------------- the --explain --

# assert_explain_source <json> <key> <expected-source>
#
# The one-line assertion every plugin suite uses over `--explain` output. Fails
# when the key is missing from `values`, missing from `sources`, or carries a
# different source than expected — so a value that is right for the wrong
# reason still fails.
assert_explain_source() {
    local json="$1" key="$2" expected="$3" actual

    if ! printf '%s' "${json}" | jq -e . >/dev/null 2>&1; then
        printf 'assert_explain_source: not valid JSON:\n%s\n' "${json}" >&2
        return 1
    fi

    if [ "$(printf '%s' "${json}" | jq --arg k "${key}" 'has("values") and (.values|has($k))')" != "true" ]; then
        printf 'assert_explain_source: key %s missing from values\n%s\n' "${key}" "${json}" >&2
        return 1
    fi

    if [ "$(printf '%s' "${json}" | jq --arg k "${key}" 'has("sources") and (.sources|has($k))')" != "true" ]; then
        printf 'assert_explain_source: key %s missing from sources\n%s\n' "${key}" "${json}" >&2
        return 1
    fi

    actual="$(printf '%s' "${json}" | jq -r --arg k "${key}" '.sources[$k]')"
    if [ "${actual}" != "${expected}" ]; then
        printf 'assert_explain_source: %s source is %s, expected %s\n' "${key}" "${actual}" "${expected}" >&2
        return 1
    fi
}

# assert_explain_complete <json> — every values key mirrored in sources.
assert_explain_complete() {
    local json="$1" missing
    missing="$(printf '%s' "${json}" | jq -r '(.values|keys) - (.sources|keys) | join(", ")')"
    if [ -n "${missing}" ]; then
        printf 'assert_explain_complete: values keys with no source: %s\n' "${missing}" >&2
        return 1
    fi
}

# ------------------------------------------------------------- assertions --

assert_status() {
    if [ "${status}" -ne "$1" ]; then
        printf 'expected exit %s, got %s\noutput:\n%s\n' "$1" "${status}" "${output}" >&2
        return 1
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'expected to contain:\n%s\nactual:\n%s\n' "$2" "$1" >&2
            return 1
            ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*)
            printf 'expected NOT to contain:\n%s\nactual:\n%s\n' "$2" "$1" >&2
            return 1
            ;;
    esac
}
