#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    source "${REPO_ROOT}/tests/helpers/common.bash"
    source "${REPO_ROOT}/tests/helpers/video-reader-fixtures.bash"
    SVR="${REPO_ROOT}/plugins/video-reader/scripts/video-read.sh"
    setup_tmp
    svr_home
    seed_base_utils
    seed_toolchain_stubs
    root="$(make_bare_fixture)"
    cd "$root"
    export VIDEO_READER_DIR="$root/runs"
    export SVR_STUB_CALLS="$root/calls.jsonl"
    : >"$SVR_STUB_CALLS"
    video="$root/clip.mp4"
    printf 'fixture media\n' >"$video"
    dir="$VIDEO_READER_DIR/case"
    report="$dir/report.json"
    unset VIDEO_READER_WHISPER_MODEL
}

teardown() {
    teardown_tmp
    hash -r
}

info() {
    export SVR_STUB_INFO_FILE="$root/info.json"
    printf '%s\n' "$1" >"$SVR_STUB_INFO_FILE"
}

calls() {
    jq -s "$1" "$SVR_STUB_CALLS"
}

@test "default duration and size caps are null, with default provenance" {
    svr_run "$SVR" --explain
    assert_status 0
    [ "$(jq -r '.values.max_duration' <<<"$output")" = null ]
    [ "$(jq -r '.values.max_size_mb' <<<"$output")" = null ]
    assert_explain_source "$output" max_duration default
    assert_explain_source "$output" max_size_mb default
}

@test "ffmpeg fixture rejects removed vsync option" {
    svr_run ffmpeg -i "$video" -vsync vfr "$root/out.jpg"
    [ "$status" -ne 0 ]
    assert_contains "$output" "Unrecognized option 'vsync'"
    [ ! -e "$root/out.jpg" ]
}

@test "a three-hour video gets bounded input seeks covering its final minute" {
    export SVR_STUB_DURATION=10800
    svr_run "$SVR" "$video" --slug case --no-stt
    assert_status 0
    jq -e '.frames.count > 0 and .frames.count <= 120 and .frames.scene.status == "skipped"' "$report"
    calls '[.[]|select(.tool=="ffmpeg")|.args|select(any(.[];endswith("-int.jpg")))] |
      length > 0 and length <= 120 and all(.[]; index("-ss") < index("-i")) and
      (map(.[index("-ss")+1]|tonumber)|max) >= 10700' | grep -qx true
    calls 'all(.[]; (.args|index("-vsync")) == null)' | grep -qx true
}

@test "zero frames from a video stream fails and points to its log" {
    export SVR_STUB_ZERO_FRAMES=1
    svr_run "$SVR" "$video" --slug case --no-stt
    assert_status 1
    assert_contains "$output" 'log'
}

@test "explicit URL duration cap refuses before media download" {
    export SVR_STUB_DURATION=1084
    svr_run "$SVR" https://example.invalid/talk --slug case --max-duration 600
    assert_status 2
    assert_contains "$output" '--max-duration'
    calls '[.[]|select(.tool=="yt-dlp")]|length == 1 and (.[0].args|index("-J")) != null' | grep -qx true
    [ ! -d "$dir/media" ] || [ -z "$(find "$dir/media" -name '*.mp4' -print)" ]
}

@test "local duration and size caps are usage errors naming their override" {
    export SVR_STUB_DURATION=1084
    svr_run "$SVR" "$video" --slug duration --max-duration 600
    assert_status 2
    assert_contains "$output" '--max-duration'
    dd if=/dev/zero of="$video" bs=1048576 count=2 2>/dev/null
    svr_run "$SVR" "$video" --slug size --max-size 1
    assert_status 2
    assert_contains "$output" '--max-size'
}

@test "unlimited URL download has no implicit size or duration filter" {
    export SVR_STUB_DURATION=1084
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames --no-stt
    assert_status 0
    calls 'all(.[]|select(.tool=="yt-dlp");
      (.args|index("--match-filter")) == null and (.args|index("--max-filesize")) == null)' | grep -qx true
}

@test "playlist and live URLs are refused before download" {
    for metadata in '{"_type":"playlist","entries":[]}' '{"id":"live","is_live":true}'; do
        info "$metadata"
        : >"$SVR_STUB_CALLS"
        svr_run "$SVR" https://example.invalid/talk --slug case
        assert_status 2
        calls '[.[]|select(.tool=="yt-dlp")]|length == 1' | grep -qx true
    done
}

@test "rolling captions collapse overlap but keep a later repeated sentence" {
    export SVR_STUB_CAPTION_FILE="$SVR_FIXTURES/rolling.srt"
    info '{"id":"talk","duration":24,"language":"en","subtitles":{},
      "automatic_captions":{"en-orig":[{"ext":"srt"}]}}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    [ -s "$dir/transcript.srt" ]
    [ -s "$dir/transcript.txt" ]
    [ "$(grep -c 'Hello world' "$dir/transcript.txt")" -eq 2 ]
    [ "$(grep -c 'A new thought' "$dir/transcript.txt")" -eq 1 ]
    [ "$(grep -c 'Last sentence' "$dir/transcript.txt")" -eq 1 ]
    grep -Eq '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$dir/transcript.txt"
    jq -e '.transcript.status == "captions" and .transcript.lines == 4' "$report"
}

@test "YouTube original auto track works without metadata language or manual captions" {
    info '{"id":"talk","extractor_key":"Youtube","duration":12,"language":null,
      "subtitles":{"live_chat":[{"ext":"json"}]},
      "automatic_captions":{"en-orig":[{"ext":"srt"}],"en":[{"ext":"srt"}]}}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    calls '[.[]|select(.tool=="yt-dlp")|.args|select(index("--sub-langs"))|
      .[index("--sub-langs")+1]] == ["en-orig"]' | grep -qx true
    jq -e '.transcript.source == "captions:auto" and .transcript.lang == "en"' "$report"
}

@test "original manual track wins over English and the English track is a companion" {
    info '{"id":"talk","extractor_key":"Other","duration":12,"language":"ru",
      "subtitles":{"ru":[{"ext":"srt"}],"en":[{"ext":"srt"}]},"automatic_captions":{}}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    jq -e '.transcript.source == "captions:manual" and .transcript.lang == "ru" and
      (.transcript.companions|length) == 1' "$report"
}

@test "non-YouTube auto captions use their ordinary original-language key" {
    info '{"id":"talk","extractor_key":"Other","duration":12,"language":"ru",
      "subtitles":{},"automatic_captions":{"ru":[{"ext":"srt"}]}}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    calls '[.[]|select(.tool=="yt-dlp")|.args|select(index("--sub-langs"))|
      .[index("--sub-langs")+1]] == ["ru"]' | grep -qx true
    jq -e '.transcript.source == "captions:auto" and .transcript.lang == "ru"' "$report"
}

@test "local Whisper runs by default and produces the canonical transcript" {
    make_whisper_home >/dev/null
    svr_run "$SVR" "$video" --slug case --no-frames
    assert_status 0
    calls '[.[]|select(.tool=="whisper-cli")]|length == 1 and
      (.[0].args|index("-osrt")) != null and (.[0].args|index("-otxt")) != null and
      (.[0].args|.[index("-l")+1]) == "auto"' | grep -qx true
    jq -e '.transcript.status == "stt" and .transcript.lines > 0 and .audio.status == "stt_done"' "$report"
    grep -q 'spoken fixture words' "$dir/transcript.txt"
}

@test "no-stt skips local Whisper even when a model exists" {
    make_whisper_home >/dev/null
    svr_run "$SVR" "$video" --slug case --no-frames --no-stt
    assert_status 0
    calls 'all(.[];.tool != "whisper-cli")' | grep -qx true
    jq -e '.transcript.status == "none"' "$report"
}

@test "forced STT replaces captions as canonical and honors explicit language" {
    make_whisper_home >/dev/null
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames --stt --stt-lang ru
    assert_status 0
    calls '[.[]|select(.tool=="whisper-cli")]|length == 1 and
      (.[0].args|.[index("-l")+1]) == "ru"' | grep -qx true
    jq -e '.transcript.status == "stt" and .transcript.lang == "ru"' "$report"
}

@test "Whisper failure and successful empty output cannot report successful transcription" {
    make_whisper_home >/dev/null
    export SVR_STUB_STT_FAIL=1
    svr_run "$SVR" "$video" --slug failed --no-frames
    assert_status 1
    jq -e '.audio.status == "stt_failed" and .transcript.status != "stt"' "$VIDEO_READER_DIR/failed/report.json"
    unset SVR_STUB_STT_FAIL
    export SVR_STUB_STT_EMPTY=1
    svr_run "$SVR" "$video" --slug empty --no-frames
    assert_status 1
    jq -e '.audio.status == "stt_failed" and .transcript.status != "stt"' "$VIDEO_READER_DIR/empty/report.json"
}

@test "audio-only media has a transcript and skips frame extraction" {
    make_whisper_home >/dev/null
    export SVR_STUB_VIDEO_STREAMS=0
    svr_run "$SVR" "$video" --slug case
    assert_status 0
    jq -e '.frames.count == 0 and .transcript.status == "stt"' "$report"
    calls 'all(.[]|select(.tool=="ffmpeg"); (.args|index("-frames:v")) == null)' | grep -qx true
}

@test "chapters survive acquisition in a timestamped TSV and the report" {
    info '{"id":"talk","duration":12,"language":"en","subtitles":{},"automatic_captions":{},
      "chapters":[{"start_time":0,"end_time":6,"title":"Opening"},
                  {"start_time":6,"end_time":12,"title":"Second part"}]}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames --no-stt
    assert_status 0
    jq -e '.chapters.count == 2 and .chapters.file != null' "$report"
    grep -q Opening "$dir/chapters.tsv"
    grep -q 'Second part' "$dir/chapters.tsv"
}

@test "scene selection includes late candidates and keeps at most sixty" {
    export SVR_STUB_DURATION=1200
    export SVR_STUB_SCENE_TIMES="$(seq 1 1199 | tr '\n' ' ')"
    svr_run "$SVR" "$video" --slug case --no-stt
    assert_status 0
    jq -e '.frames.scene.status == "enabled" and .frames.scene.candidates == 1199 and
      .frames.scene.selected > 0 and .frames.scene.selected <= 60' "$report"
    calls '[.[]|select(.tool=="ffmpeg")|.args|select(any(.[];endswith("-cut.jpg")))|
      .[index("-ss")+1]|tonumber]|max > 1100' | grep -qx true
}

@test "explicit scene threshold enables detection beyond twenty minutes" {
    export SVR_STUB_DURATION=1800
    export SVR_STUB_SCENE_TIMES='10 900 1790'
    svr_run "$SVR" "$video" --slug case --scene 0.4 --no-stt
    assert_status 0
    jq -e '.frames.scene.status == "enabled" and .frames.scene.threshold == 0.4' "$report"
    calls 'any(.[]|select(.tool=="ffmpeg");any(.args[];contains("gt(scene,0.4)")))' | grep -qx true
}

@test "sheet index accounts for every frame in numeric time order beyond 99999 seconds" {
    export SVR_STUB_DURATION=108000
    svr_run "$SVR" "$video" --slug case --no-stt
    assert_status 0
    index="$dir/sheets/index.tsv"
    [ -s "$index" ]
    expected="$(jq -r '.frames.count' "$report")"
    [ "$(awk 'END{print NR-1}' "$index")" -eq "$expected" ]
    awk -F '\t' 'NR==1 {next} {if ($3+0 < prev || $2<1 || $2>16) exit 1; prev=$3+0}
      END {if (prev < 100000) exit 1}' "$index"
    while IFS=$'\t' read -r sheet cell seconds hms kind frame; do
        [ "$sheet" = sheet ] && continue
        case "$sheet" in /*) sheet_path="$sheet" ;; *) sheet_path="$dir/sheets/$sheet" ;; esac
        [ -s "$sheet_path" ]
    done <"$index"
}

@test "window reuses acquired media and creates dense timestamped sheets" {
    export SVR_STUB_DURATION=10800
    svr_run "$SVR" "$video" --slug case --no-stt
    assert_status 0
    : >"$SVR_STUB_CALLS"
    svr_run "$SVR" --window "$dir" 01:00:00 01:00:10 2
    assert_status 0
    calls 'all(.[];.tool != "yt-dlp" and .tool != "whisper-cli")' | grep -qx true
    calls '[.[]|select(.tool=="ffmpeg")|.args|select(index("-ss"))|
      .[index("-ss")+1]|tonumber]|
      length >= 5 and all(.[]; . >= 3600 and . <= 3610)' | grep -qx true
    [ -n "$(find "$dir/sheets" -name 'window-*.tsv' -print)" ]
    [ -n "$(find "$dir/sheets" -name 'window-*.jpg' -print)" ]
}

@test "window rejects reversed and out-of-range bounds without extraction" {
    svr_run "$SVR" "$video" --slug case --no-stt
    assert_status 0
    : >"$SVR_STUB_CALLS"
    svr_run "$SVR" --window "$dir" 10 2
    assert_status 2
    svr_run "$SVR" --window "$dir" 20 30
    assert_status 2
    calls 'length == 0' | grep -qx true
}

@test "both URL calls ignore external config and disable geographic bypass" {
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames --no-stt
    assert_status 0
    calls '[.[]|select(.tool=="yt-dlp")]|length == 2 and all(.[];
      (.args|index("--ignore-config")) != null and (.args|index("--no-geo-bypass")) != null and
      (.args|index("--no-cookies")) != null and (.args|index("--no-cookies-from-browser")) != null)' | grep -qx true
}

@test "local caps compare exact bytes and fractional seconds" {
    export SVR_STUB_DURATION=600.9
    svr_run "$SVR" "$video" --slug duration --max-duration 600
    assert_status 2
    assert_contains "$output" '--max-duration'
    unset SVR_STUB_DURATION
    dd if=/dev/zero of="$video" bs=1048576 count=1 2>/dev/null
    printf x >>"$video"
    svr_run "$SVR" "$video" --slug size --max-size 1
    assert_status 2
    assert_contains "$output" '--max-size'
}

@test "metadata language reaches Whisper with its region stripped" {
    make_whisper_home >/dev/null
    export SVR_STUB_YTDLP_SUBS=0
    info '{"id":"talk","duration":12,"language":"ru-RU","subtitles":{},"automatic_captions":{}}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    calls '[.[]|select(.tool=="whisper-cli")]|length == 1 and
      (.[0].args|.[index("-l")+1]) == "ru"' | grep -qx true
    jq -e '.transcript.lang == "ru"' "$report"
}

@test "profile transcription language outranks metadata and flag outranks profile" {
    make_whisper_home >/dev/null
    write_profile "$root" '{"stt_lang":"de"}' >/dev/null
    info '{"id":"talk","duration":12,"language":"ru","subtitles":{},"automatic_captions":{}}'
    export SVR_STUB_YTDLP_SUBS=0
    svr_run "$SVR" https://example.invalid/talk --slug profile --no-frames
    assert_status 0
    jq -e '.transcript.lang == "de"' "$VIDEO_READER_DIR/profile/report.json"
    svr_run "$SVR" https://example.invalid/talk --slug flag --no-frames --stt-lang fr
    assert_status 0
    jq -e '.transcript.lang == "fr"' "$VIDEO_READER_DIR/flag/report.json"
}

@test "empty caption-track arrays trigger STT instead of a false caption claim" {
    make_whisper_home >/dev/null
    info '{"id":"talk","duration":12,"language":"en","subtitles":{"en":[]},"automatic_captions":{}}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    jq -e '.transcript.status == "stt"' "$report"
}

@test "regional metadata falls back to the base-language original auto key" {
    info '{"id":"talk","duration":12,"language":"en-US","subtitles":{},
      "automatic_captions":{"en-orig":[{"ext":"srt"}],"en":[{"ext":"srt"}]}}'
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    calls '[.[]|select(.tool=="yt-dlp")|.args|select(index("--sub-langs"))|
      .[index("--sub-langs")+1]] == ["en-orig"]' | grep -qx true
    jq -e '.transcript.source == "captions:auto" and .transcript.lang == "en"' "$report"
}

@test "the same words spoken after a quiet gap survive caption normalization" {
    export SVR_STUB_CAPTION_FILE="$root/repeated.srt"
    printf '1\n00:00:01,000 --> 00:00:03,000\nThank you\n\n2\n00:00:20,000 --> 00:00:22,000\nThank you\n' >"$SVR_STUB_CAPTION_FILE"
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    [ "$(grep -c 'Thank you' "$dir/transcript.txt")" -eq 2 ]
}

@test "sheet creation failure cannot return success with a dangling index" {
    export SVR_STUB_SHEET_FAIL=1
    svr_run "$SVR" "$video" --slug case --no-stt
    assert_status 1
    assert_contains "$output" 'log'
}

@test "reusing a slug for a new URL cannot analyze an old local media file" {
    old="$root/a-old.mp4"
    printf 'old fixture\n' >"$old"
    svr_run "$SVR" "$old" --slug case --no-frames --no-stt
    assert_status 0
    svr_run "$SVR" https://example.invalid/new --slug case --no-frames --no-stt
    assert_status 0
    jq -e '.source.media == "media/fixture-clip.mp4"' "$report"
}

@test "a zero profile interval is rejected before it can start an endless sampling loop" {
    write_profile "$root" '{"interval":0}' >/dev/null
    svr_run "$SVR" --explain
    assert_status 2
    assert_contains "$output" 'interval'
}

@test "manual captions preserve deliberate repeated words in touching cues" {
    export SVR_STUB_CAPTION_FILE="$root/manual-repeat.srt"
    printf '1\n00:00:01,000 --> 00:00:03,000\nYes\n\n2\n00:00:03,000 --> 00:00:05,000\nYes\n' >"$SVR_STUB_CAPTION_FILE"
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames
    assert_status 0
    [ "$(grep -c 'Yes' "$dir/transcript.txt")" -eq 2 ]
}

@test "embedded local captions become a transcript without invoking Whisper" {
    make_whisper_home >/dev/null
    export SVR_STUB_SUBTITLE_STREAMS=1
    svr_run "$SVR" "$video" --slug case --no-frames
    assert_status 0
    jq -e '.transcript.source == "captions:embedded" and .transcript.lines > 0' "$report"
    grep -q 'Embedded fixture words' "$dir/transcript.txt"
    calls 'all(.[]; .tool != "whisper-cli")' | grep -qx true
}

@test "a URL output exceeding the size cap is refused after acquisition" {
    svr_run "$SVR" https://example.invalid/talk --slug case --no-frames --no-stt --max-size 0.000001
    assert_status 2
    assert_contains "$output" '--max-size'
}

@test "video-only suppresses local Whisper and reports the explicit reason" {
    make_whisper_home >/dev/null
    svr_run "$SVR" "$video" --slug case --video-only --no-frames
    assert_status 0
    calls 'all(.[]; .tool != "whisper-cli")' | grep -qx true
    jq -e '.transcript.status == "none" and (.audio.reason|contains("--video-only"))' "$report"
}

@test "video-only and forced STT are refused before doing work in either flag order" {
    make_whisper_home >/dev/null
    svr_run "$SVR" "$video" --slug case --video-only --stt
    assert_status 2
    assert_contains "$output" '--video-only'
    assert_contains "$output" '--stt'
    svr_run "$SVR" "$video" --slug case --stt --video-only
    assert_status 2
    calls 'length == 0' | grep -qx true
    [ ! -d "$dir" ]
}
