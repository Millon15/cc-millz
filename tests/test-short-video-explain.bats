#!/usr/bin/env bats
#
# tests/test-short-video-explain.bats — the --explain contract and the four
# consumers that read the resolved base back out.
#
# The rung ladder itself is asserted next door, in test-short-video-workdir.bats.
# What this suite covers is everything the seam PROMISES beyond the rung: that an
# inspection prints without writing, that the paths it and the run hand back can
# actually be opened, that report.json describes directories that exist, and that
# --probe and --explain never drift into two answers about one machine.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	source "${REPO_ROOT}/tests/helpers/short-video-fixtures.bash"
	SVR="${REPO_ROOT}/plugins/short-video-reader/scripts/short-video-read.sh"

	setup_tmp
	svr_home
	seed_base_utils
	seed_toolchain_stubs

	TMPDIR="${TMP}/ostemp"
	mkdir -p "${TMPDIR}"
	export TMPDIR

	unset SHORT_VIDEO_DIR SHORT_VIDEO_WHISPER_MODEL
}

teardown() {
	# hash -r AFTER the delete: teardown_tmp resolves `rm` through the stub
	# directory setup_tmp prepended, bash caches that path, and bats own `rm -f`
	# a moment later then follows the cache into the directory just removed.
	teardown_tmp
	hash -r
}

# Every case reaches the reader through svr_run, which REPLACES PATH with the
# stub directory alone for that invocation, never prepends, and never stubs jq —
# the report is written with `jq -n` and assert_explain_source shells out to jq
# itself, so a stub that exits 0 would empty both readings.

# --------------------------------------------------------------- the contract

@test "--explain prints the documented shape and mirrors every value in sources" {
	root="$(make_bare_fixture)"
	cd "${root}"

	svr_run "${SVR}" --explain
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.plugin')" = "short-video-reader" ]
	assert_explain_complete "${output}"
	assert_explain_source "${output}" workdir default
	assert_explain_source "${output}" tools detected:path
}

@test "a profile sets the caps, and --explain says which ones it set" {
	root="${HOME}/caps-fixture"
	write_profile "${root}" '{"workdir":"scratch","max_duration":42,"max_height":480,"stt_lang":"ru"}' >/dev/null
	cd "${root}"

	svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_complete "${output}"

	assert_explain_source "${output}" max_duration profile
	assert_explain_source "${output}" max_height profile
	assert_explain_source "${output}" stt_lang profile
	assert_explain_source "${output}" max_size_mb default
	assert_explain_source "${output}" interval default

	[ "$(printf '%s' "${output}" | jq -r '.values.max_duration')" = "42" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.max_height')" = "480" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.stt_lang')" = "ru" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.max_size_mb')" = "250" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.interval')" = "null" ]
}

@test "--explain creates NO file and NO directory under the base it resolved" {
	root="$(make_bare_fixture)"
	model="$(make_whisper_home)"
	[ -f "${model}" ]
	base="${TMP}/inspection-base"
	cd "${root}"
	export SHORT_VIDEO_DIR="${base}"

	svr_run "${SVR}" --explain
	assert_status 0

	# The write this case is about is the model cache, and it is only reached
	# when a whisper binary AND a GGML model are both found. Asserting the
	# detection got that far is what makes the absence below mean something.
	[ "$(printf '%s' "${output}" | jq -r '.values.tools.stt')" = "whisper-cli" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.tools.stt_model')" = "${model}" ]

	if [ -e "${base}" ]; then
		printf 'an inspection created %s:\n' "${base}" >&2
		find "${base}" >&2
		return 1
	fi
}

# ------------------------------------------------------------ --probe agreement

@test "--probe and --explain report the same verdict for every tool" {
	root="$(make_bare_fixture)"
	make_whisper_home >/dev/null
	cd "${root}"

	svr_run "${SVR}" --probe
	assert_status 0
	probe="${output}"

	svr_run "${SVR}" --explain
	assert_status 0
	explain="${output}"

	for t in ffmpeg ffprobe yt-dlp tesseract jq; do
		reported="$(printf '%s\n' "${probe}" | awk -v t="${t}" '$1 == t { print $2 }')"
		resolved="$(printf '%s' "${explain}" | jq -r --arg t "${t}" '.values.tools[$t] // "MISSING"')"
		if [ "${reported}" != "${resolved}" ]; then
			printf '%s: --probe says %s, --explain says %s\n' "${t}" "${reported}" "${resolved}" >&2
			return 1
		fi
	done

	assert_contains "${probe}" "available: whisper-cli"
	[ "$(printf '%s' "${explain}" | jq -r '.values.tools.stt')" = "whisper-cli" ]
}

# ------------------------------------------------------------- the printed path

@test "--zoom prints a path that opens from the cwd the command ran in" {
	root="$(make_bare_fixture)"
	video="${root}/clip.mp4"
	printf 'short-video-reader fixture artifact — not a real media file\n' >"${video}"
	cd "${root}"
	# The base sits UNDER the cwd, so a caller-relative print is possible at all.
	export SHORT_VIDEO_DIR="${root}/scratch"

	svr_run "${SVR}" "${video}" --slug zoomed
	assert_status 0

	svr_run "${SVR}" --zoom "${root}/scratch/zoomed" 4
	assert_status 0
	printed="${output}"
	case "${printed}" in
	/*)
		printf 'an absolute path was printed for a frame beneath the cwd: %s\n' "${printed}" >&2
		return 1
		;;
	esac
	[ -r "${printed}" ]
}

@test "--zoom finds the media WITHOUT the override that produced the run" {
	root="$(make_bare_fixture)"
	video="${root}/clip.mp4"
	printf 'short-video-reader fixture artifact — not a real media file\n' >"${video}"
	base="${TMP}/detached-base"
	cd "${root}"

	SHORT_VIDEO_DIR="${base}" svr_run "${SVR}" "${video}" --slug detached
	assert_status 0

	unset SHORT_VIDEO_DIR
	svr_run "${SVR}" --zoom "${base}/detached" 2
	assert_status 0
	[ -r "${output}" ]
}

# ------------------------------------------------------------------ the report

@test "report.json describes directories that exist on disk" {
	root="$(make_bare_fixture)"
	video="${root}/clip.mp4"
	printf 'short-video-reader fixture artifact — not a real media file\n' >"${video}"
	base="${TMP}/report-base"
	cd "${root}"
	export SHORT_VIDEO_DIR="${base}"

	svr_run "${SVR}" "${video}" --slug reported
	assert_status 0

	report="${base}/reported/report.json"
	[ -f "${report}" ]
	for key in .source.run_dir .captions.dir .frames.dir .frames.sheets_dir; do
		dir="$(jq -r "${key}" "${report}")"
		if [ ! -d "${dir}" ]; then
			printf '%s is %s, which is not a directory\n' "${key}" "${dir}" >&2
			return 1
		fi
	done
	[ "$(jq -r '.source.run_dir' "${report}")" = "${base}/reported" ]
}
