#!/usr/bin/env bash
#
# tests/fixtures/short-video-reader/stubs/ffmpeg.bash
#
# BEHAVIOURAL stub. The reader invokes ffmpeg five different ways and then reads
# what each invocation LEFT ON DISK, so a stub that only exits 0 makes every
# downstream count zero and every directory empty:
#
#   scene cut     -vf select='gt(scene,…)',showinfo …  frames/raw-scene-%04d.jpg
#                 the caller greps `pts_time:` out of the log to rename them
#   interval      -vf fps=1/N …                        frames/raw-int-%04d.jpg
#   contact sheet -pattern_type glob -i frames/*.jpg …  sheets/sheet-%02d.jpg
#   captions      -map 0:s:0 …                          subs/embedded.srt
#   audio / zoom  a single named output file
#
# So the rule here is: the LAST argument is the output. When it carries a printf
# frame pattern, write SVR_STUB_FRAMES files through it; otherwise write the one
# file. The scene pass additionally prints one showinfo line per frame, because
# the rename loop is driven by those timestamps and not by the files.
#
# Nothing written is a real media file — every artifact is a text placeholder,
# which is all the reader ever does with them (it counts and moves them).

set -euo pipefail

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
for a in "${args[@]}"; do
	case "${a}" in
	glob) is_glob_input=1 ;;
	*showinfo*) want_showinfo=1 ;;
	esac
done

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

write_placeholder() {
	printf 'short-video-reader fixture artifact — not a real media file\n' >"$1"
}

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
