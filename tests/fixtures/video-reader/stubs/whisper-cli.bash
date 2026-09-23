#!/usr/bin/env bash
# Produces transcripts only when the reader actually invokes the CLI.
set -euo pipefail
if [ -n "${SVR_STUB_CALLS:-}" ]; then
    jq -cn --arg tool whisper-cli --args '{tool:$tool,args:$ARGS.positional}' -- "$@" >>"${SVR_STUB_CALLS}"
fi
[ "${SVR_STUB_STT_FAIL:-0}" = 1 ] && exit 1
of=""
model=""
audio=""
want_txt=0
want_srt=0
prev=""
for a in "$@"; do
    case "$prev" in
    -of) of="$a" ;;
    -m) model="$a" ;;
    -f) audio="$a" ;;
    esac
    [ "$a" = -otxt ] && want_txt=1
    [ "$a" = -osrt ] && want_srt=1
    prev="$a"
done
[ -f "$model" ] && [ -f "$audio" ] && [ -n "$of" ] || exit 1
[ "${SVR_STUB_STT_EMPTY:-0}" = 1 ] && exit 0
mkdir -p "$(dirname "$of")"
if [ "$want_txt" = 1 ]; then printf 'spoken fixture words\n' >"$of.txt"; fi
if [ "$want_srt" = 1 ]; then
    printf '1\n00:00:00,000 --> 00:00:02,000\nspoken fixture words\n' >"$of.srt"
fi
exit 0
