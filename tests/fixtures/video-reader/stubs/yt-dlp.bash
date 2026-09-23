#!/usr/bin/env bash
# Offline acquisition with separate metadata and download calls.
set -euo pipefail

if [ -n "${SVR_STUB_CALLS:-}" ]; then
    jq -cn --arg tool yt-dlp --args '{tool:$tool,args:$ARGS.positional}' -- "$@" >>"${SVR_STUB_CALLS}"
fi
if [ "${SVR_STUB_YTDLP_FAIL:-0}" = 1 ]; then
    printf 'ERROR: fixture acquisition failed\n' >&2
    exit 1
fi

metadata() {
    if [ -n "${SVR_STUB_INFO_FILE:-}" ]; then
        cat "${SVR_STUB_INFO_FILE}"
    else
        jq -n --argjson duration "${SVR_STUB_DURATION:-12}" \
            '{id:"fixture-clip",title:"Fixture clip",extractor:"fixture",language:"en",
            webpage_url:"https://example.invalid/watch?v=fixture-clip",duration:$duration,
            subtitles:{en:[{ext:"srt",url:"https://example.invalid/en.srt"}]},
            automatic_captions:{},chapters:[]}'
    fi
}

template=""
languages="en"
prev=""
preflight=0
want_subs=0
manual=0
automatic=0
for a in "$@"; do
    case "$prev" in
    -o | --output) template="$a" ;;
    --sub-langs) languages="$a" ;;
    esac
    case "$a" in
    -J | --dump-single-json | --dump-json | -j) preflight=1 ;;
    --write-subs)
        want_subs=1
        manual=1
        ;;
    --write-auto-subs)
        want_subs=1
        automatic=1
        ;;
    esac
    prev="$a"
done
if [ "$preflight" = 1 ]; then
    metadata
    exit 0
fi
[ -n "$template" ] || {
    printf 'missing output template\n' >&2
    exit 2
}
dir="$(dirname "$template")"
mkdir -p "$dir"
metadata >"$dir/fixture-clip.info.json"
printf 'fixture media\n' >"$dir/fixture-clip.mp4"
if [ "${SVR_STUB_YTDLP_SUBS:-1}" = 1 ] && [ "$want_subs" = 1 ]; then
    old_ifs="$IFS"
    IFS=,
    for lang in $languages; do
        metadata | jq -e --arg lang "$lang" --argjson manual "$manual" --argjson automatic "$automatic" \
            '($manual == 1 and ((.subtitles[$lang] // [])|length) > 0) or
           ($automatic == 1 and ((.automatic_captions[$lang] // [])|length) > 0)' >/dev/null || continue
        if [ -n "${SVR_STUB_CAPTION_FILE:-}" ]; then
            cp "$SVR_STUB_CAPTION_FILE" "$dir/fixture-clip.$lang.srt"
        else
            printf '1\n00:00:01,000 --> 00:00:03,000\nfixture caption line one\n\n2\n00:00:04,000 --> 00:00:06,000\nfixture caption line two\n' >"$dir/fixture-clip.$lang.srt"
        fi
    done
    IFS="$old_ifs"
fi
