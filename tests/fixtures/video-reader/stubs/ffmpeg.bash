#!/usr/bin/env bash
# Produces artifact files for seeks, sheets, captions and audio. Scene scans
# write candidate timestamps to the metadata filter's output path. All media
# placeholders stay offline; real ffmpeg is exercised by the live test runner.

set -euo pipefail

if [ -n "${SVR_STUB_CALLS:-}" ]; then
    jq -cn --arg tool ffmpeg --args '{tool:$tool,args:$ARGS.positional}' -- "$@" >>"${SVR_STUB_CALLS}"
fi
for arg in "$@"; do
    if [ "$arg" = "-vsync" ]; then
        printf "Unrecognized option 'vsync'.\n" >&2
        exit 8
    fi
done

frames="${SVR_STUB_FRAMES:-3}"
scene_times="${SVR_STUB_SCENE_TIMES:-1.000 4.000 8.000}"

[ "$#" -gt 0 ] || {
    printf 'ffmpeg-stub: called with no arguments\n' >&2
    exit 2
}

args=("$@")
out="${args[$# - 1]}"

is_glob_input=0
input=""
want_showinfo=0
scene_file=""
for a in "${args[@]}"; do
    case "${a}" in
    glob) is_glob_input=1 ;;
    *showinfo*) want_showinfo=1 ;;
    esac
    case "${a}" in
    *metadata=print:file=*) scene_file="${a##*metadata=print:file=}" ;;
    esac
done

if [ -n "$scene_file" ]; then
    mkdir -p "$(dirname "$scene_file")"
    : >"$scene_file"
    for t in $scene_times; do
        printf 'frame:0 pts:0 pts_time:%s\n' "$t" >>"$scene_file"
    done
    exit 0
fi

# The input is the argument after the last -i.
i=0
while [ "${i}" -lt "$#" ]; do
    [ "${args[${i}]}" = "-i" ] && input="${args[$((i + 1))]}"
    i=$((i + 1))
done

if [ "${is_glob_input}" -eq 0 ] && [ -n "${input}" ] && [ ! -f "${input}" ]; then
    printf 'ffmpeg-stub: no such input file: %s\n' "${input}" >&2
    exit 1
fi

case "${out}" in
-*)
    printf 'ffmpeg-stub: last argument is a flag, not an output: %s\n' "${out}" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "${out}")"

case "${out}" in
*.jpg)
    [ "${SVR_STUB_ZERO_FRAMES:-0}" = 1 ] && exit 0
    [ "${SVR_STUB_FRAME_FAIL:-0}" = 1 ] && exit 1
    ;;
*.srt)
    if [ -n "${SVR_STUB_CAPTION_FILE:-}" ]; then
        cp "${SVR_STUB_CAPTION_FILE}" "${out}"
    else
        printf '1\n00:00:01,000 --> 00:00:03,000\nEmbedded fixture words\n' >"${out}"
    fi
    exit 0
    ;;
esac

write_placeholder() {
    printf 'video-reader fixture artifact — not a real media file\n' >"$1"
}

if [[ "$input" == */.concat.txt ]]; then
    [ "${SVR_STUB_SHEET_FAIL:-0}" = 1 ] && exit 1
    count="$(wc -l <"$input")"
    frames=$(((count + 15) / 16))
fi

case "${out}" in
*%0*d*)
    n=1
    while [ "${n}" -le "${frames}" ]; do
        # shellcheck disable=SC2059
        write_placeholder "$(printf "${out}" "${n}")"
        n=$((n + 1))
    done
    ;;
*)
    write_placeholder "${out}"
    ;;
esac

# showinfo goes to stderr in the real tool and the caller merges both streams
# into the log it greps, so either stream would do; stderr is the honest one.
if [ "${want_showinfo}" -eq 1 ]; then
    n=0
    for t in ${scene_times}; do
        printf '[Parsed_showinfo_1 @ 0x0] n:%d pts:%d pts_time:%s pos:0 fmt:yuvj420p\n' \
            "${n}" "${n}" "${t}" >&2
        n=$((n + 1))
        [ "${n}" -ge "${frames}" ] && break
    done
fi

exit 0
