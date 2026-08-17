#!/usr/bin/env bash
#
# review-preflight.sh (ralphex-revmux plugin) — LIVE preflight for a ralphex run whose
# external reviewer is revmux: codex auth round-trip (shared by ralphex's codex phase AND revmux's
# codex finders), revmux presence + profile resolution, claude presence.
#
# WHY: `codex doctor` / the companion `setup` only prove ~/.codex/auth.json HAS
# tokens, not that they WORK — the ChatGPT refresh token is single-use, so a
# stale copy 401s ~2h into a run. The ONLY reliable check is a real turn, and a
# successful turn also ROTATES the token fresh (gate + warm-up). Runs at
# BEFORE anything launches — never a silent degrade.
#
# Usage:
#   review-preflight.sh [--engine revmux|ralphex] [--profile <name>] [--no-codex] [--human]
#   (profile default: $RALPHEX_REVMUX_PROFILE, else sol-panel — the revmux-kit roster)
#
# Verdict JSON (default) on stdout:
#   {"codex":"OK|STALE|UNKNOWN|ABSENT|SKIPPED","revmux":"OK|ABSENT|PROFILE_MISSING|SKIPPED",
#    "claude":"OK|ABSENT","profile":"<resolved>","exit":N,"detail":"..."}
#
# Exit codes:
#   0  everything the chosen engine needs is live
#   1  codex auth STALE  → fix: codex logout && codex login, then re-run
#   2  codex UNKNOWN (timeout / no verdict) → retry once, then treat as STALE
#   3  hard-missing: claude absent, revmux absent, or the profile does not resolve
#
# codex ABSENT (not on PATH) or --no-codex → codex check SKIPPED, the resolved
# profile falls back to its no-codex twin — <profile>-claude, or sol-* → fable-* for the
# revmux-kit rosters (revmux engine) — a warn, not a stop.
#
set -uo pipefail

ENGINE=revmux
PROFILE="${RALPHEX_REVMUX_PROFILE:-sol-panel}"
NO_CODEX=0
JSON=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)
            ENGINE="$2"
            shift 2
            ;;
        --engine=*)
            ENGINE="${1#*=}"
            shift
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#*=}"
            shift
            ;;
        --no-codex)
            NO_CODEX=1
            shift
            ;;
        --human | --text)
            JSON=0
            shift
            ;;
        --json)
            JSON=1
            shift
            ;;
        *)
            echo "review-preflight: unknown arg $1" >&2
            exit 3
            ;;
    esac
done

CODEX=SKIPPED
REVMUX=SKIPPED
CLAUDE=ABSENT
CODE=0
DETAIL=""
OUT="$(mktemp -t review-preflight.XXXXXX)"
trap 'test -f "$OUT" && command rm -f -- "$OUT"' EXIT

emit() {
    if [[ $JSON -eq 1 ]]; then
        printf '{"codex":"%s","revmux":"%s","claude":"%s","profile":"%s","exit":%s,"detail":"%s"}\n' \
            "$CODEX" "$REVMUX" "$CLAUDE" "$PROFILE" "$CODE" "$DETAIL"
    else
        printf 'review-preflight: codex=%s revmux=%s claude=%s profile=%s — %s\n' \
            "$CODEX" "$REVMUX" "$CLAUDE" "$PROFILE" "$DETAIL"
    fi
    exit "$CODE"
}

fail() { # $1=exit  $2=detail
    CODE="$1"
    DETAIL="$2"
    emit
}

check_claude() {
    command -v claude >/dev/null 2>&1 || fail 3 "claude CLI not on PATH"
    CLAUDE=OK
}

# One-shot `codex exec` bounded to 60s; stdin closed so codex never blocks on
# "Reading additional input from stdin...". macOS has no `timeout` by default →
# background watchdog fallback.
run_codex_probe() {
    local rc deadline=60 timeout_bin
    timeout_bin="$(command -v timeout || command -v gtimeout || true)"
    if [[ -n "$timeout_bin" ]]; then
        "$timeout_bin" "$deadline" codex exec --json -s read-only --skip-git-repo-check \
            "Reply with exactly the token CODEX_OK and nothing else." </dev/null >"$OUT" 2>&1
        return $?
    fi
    codex exec --json -s read-only --skip-git-repo-check \
        "Reply with exactly the token CODEX_OK and nothing else." </dev/null >"$OUT" 2>&1 &
    local cpid=$! wpid
    (
        sleep "$deadline"
        kill -TERM "$cpid" 2>/dev/null
    ) &
    wpid=$!
    wait "$cpid" 2>/dev/null
    rc=$?
    kill -TERM "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null || true
    [[ $rc -gt 128 ]] && rc=124
    return $rc
}

judge_codex_probe() { # $1=rc of the probe
    if grep -q '"type":"turn.completed"' "$OUT" && grep -q 'CODEX_OK' "$OUT"; then
        CODEX=OK
        return 0
    fi
    if grep -qiE 'refresh token was already used|Failed to refresh token|401 Unauthorized|"type":"turn.failed"' "$OUT"; then
        CODEX=STALE
        fail 1 "stale ChatGPT auth — run: codex logout && codex login (logout FIRST), then re-run"
    fi
    CODEX=UNKNOWN
    [[ "$1" -eq 124 ]] && fail 2 "codex exec timed out (60s) — network/websocket; retry or check connectivity"
    fail 2 "codex exec produced no clear verdict (rc=$1) — inspect ${OUT}"
}

check_codex() {
    if [[ $NO_CODEX -eq 1 ]]; then
        CODEX=SKIPPED
        DETAIL="codex skipped by --no-codex"
        return 0
    fi
    if ! command -v codex >/dev/null 2>&1; then
        CODEX=ABSENT
        DETAIL="codex CLI not on PATH — check skipped"
        return 0
    fi
    run_codex_probe
    judge_codex_probe $?
}

fallback_profile_without_codex() {
    [[ "$CODEX" == "OK" ]] && return 0
    [[ "$ENGINE" == "revmux" ]] || return 0
    case "$PROFILE" in
        sol-*) PROFILE="fable-${PROFILE#sol-}" ;;
        *-claude | fable-*) ;;
        *) PROFILE="${PROFILE}-claude" ;;
    esac
}

check_revmux() {
    if [[ "$ENGINE" != "revmux" ]]; then
        REVMUX=SKIPPED
        return 0
    fi
    command -v revmux >/dev/null 2>&1 || {
        REVMUX=ABSENT
        fail 3 "revmux not on PATH — brew install umputun/apps/revmux"
    }
    if ! revmux config 2>/dev/null | jq -e --arg p "$PROFILE" '.profiles[] | select(.name == $p)' >/dev/null; then
        REVMUX=PROFILE_MISSING
        fail 3 "revmux profile '$PROFILE' does not resolve — run the revmux-kit bootstrap or check .revmux/prompts/profiles/"
    fi
    REVMUX=OK
}

check_claude
check_codex
fallback_profile_without_codex
check_revmux
[[ -n "$DETAIL" ]] || DETAIL="all live — engine=$ENGINE profile=$PROFILE"
emit
