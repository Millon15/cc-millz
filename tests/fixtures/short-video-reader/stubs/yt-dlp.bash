#!/usr/bin/env bash
#
# tests/fixtures/short-video-reader/stubs/yt-dlp.bash
#
# BEHAVIOURAL stub. After the download the reader looks for THREE things the
# real tool leaves behind, and an `exit 0` stub leaves none of them:
#
#   media/<id>.info.json   slurped into report.json as the provenance block
#   media/<id>.<ext>       the first non-sidecar file, taken as the media
#   media/<id>.*.srt       moved into subs/ and counted as captions
#
# With none of those present the reader dies with "yt-dlp produced no media
# file", so every URL case would assert an acquisition failure instead of the
# acquisition.
#
# The output directory comes from the -o template; the id and extension in that
# template are ignored and a fixed id is used, so the artifact names are stable
# enough to assert against.
#
#   SVR_STUB_YTDLP_FAIL=1   exit 1 after writing the log, for the failure-hint case
#   SVR_STUB_YTDLP_SUBS=0   write no .srt, so a URL run reaches the STT rung
#
# The webpage_url below is under .invalid, the TLD RFC 2606 reserves as
# guaranteed-nonresolvable: no fixture here names a real host.

set -euo pipefail

id="${SVR_STUB_YTDLP_ID:-fixture-clip}"
want_subs="${SVR_STUB_YTDLP_SUBS:-1}"

template=""
prev=""
for a in "$@"; do
	[ "${prev}" = "-o" ] && template="${a}"
	prev="${a}"
done

[ -n "${template}" ] || {
	printf 'yt-dlp-stub: no -o template in the argument list\n' >&2
	exit 2
}

dir="$(dirname "${template}")"
mkdir -p "${dir}"

printf '[fixture] destination %s\n' "${dir}"
printf '[download] 100%% of 4.00KiB in 00:00\n'

if [ "${SVR_STUB_YTDLP_FAIL:-0}" = "1" ]; then
	printf 'ERROR: [fixture] %s: this stub was asked to fail\n' "${id}" >&2
	exit 1
fi

cat >"${dir}/${id}.info.json" <<JSON
{
  "id": "${id}",
  "title": "Fixture clip",
  "uploader": "fixture-uploader",
  "upload_date": "20200101",
  "extractor": "fixture",
  "webpage_url": "https://example.invalid/watch?v=${id}",
  "format": "fixture-360p",
  "duration": 12
}
JSON

printf 'short-video-reader fixture artifact — not a real media file\n' >"${dir}/${id}.mp4"

if [ "${want_subs}" = "1" ]; then
	cat >"${dir}/${id}.en.srt" <<'SRT'
1
00:00:01,000 --> 00:00:03,000
fixture caption line one

2
00:00:04,000 --> 00:00:06,000
fixture caption line two
SRT
fi

exit 0
