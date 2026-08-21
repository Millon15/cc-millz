#!/usr/bin/env bash
#
# tests/fixtures/short-video-reader/stubs/ffprobe.bash
#
# BEHAVIOURAL stub. The reader calls ffprobe exactly once:
#
#     ffprobe -v error -print_format json -show_format -show_streams <media>
#
# and then reads .format.duration, the first video stream's width/height/
# r_frame_rate, and the COUNT of audio and subtitle streams out of the JSON it
# printed. An `exit 0` stub returns an empty inventory, every one of those reads
# falls back to 0, and the frame branch is skipped because WIDTH is 0 — so the
# suite would be green over a code path that never ran.
#
# The inventory below is therefore a real answer, and a deliberately small one:
#
#   duration 12s   under every cap, so no case trips the duration guard
#   640x360        non-zero width, so the frame branch is entered
#   1 audio        so the audio policy is reached
#   0 subtitle     so the embedded-caption extraction is NOT triggered and the
#                  STT rung is what a local-file run exercises
#
# Override any of them per case with SVR_STUB_DURATION / _WIDTH / _HEIGHT /
# _AUDIO_STREAMS / _SUBTITLE_STREAMS.

set -euo pipefail

duration="${SVR_STUB_DURATION:-12.000000}"
width="${SVR_STUB_WIDTH:-640}"
height="${SVR_STUB_HEIGHT:-360}"
audio="${SVR_STUB_AUDIO_STREAMS:-1}"
subs="${SVR_STUB_SUBTITLE_STREAMS:-0}"

streams=""
sep=""

emit_stream() {
	streams="${streams}${sep}$1"
	sep=","
}

emit_stream "{\"index\":0,\"codec_type\":\"video\",\"codec_name\":\"h264\",\"width\":${width},\"height\":${height},\"r_frame_rate\":\"30/1\"}"

i=1
while [ "${i}" -le "${audio}" ]; do
	emit_stream "{\"index\":${i},\"codec_type\":\"audio\",\"codec_name\":\"aac\",\"channels\":2,\"sample_rate\":\"48000\"}"
	i=$((i + 1))
done

j=0
while [ "${j}" -lt "${subs}" ]; do
	emit_stream "{\"index\":${i},\"codec_type\":\"subtitle\",\"codec_name\":\"mov_text\"}"
	i=$((i + 1))
	j=$((j + 1))
done

printf '{"streams":[%s],"format":{"format_name":"mov,mp4","duration":"%s","size":"4096","bit_rate":"2730"}}\n' \
	"${streams}" "${duration}"
