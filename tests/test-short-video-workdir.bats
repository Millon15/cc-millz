#!/usr/bin/env bats
#
# tests/test-short-video-workdir.bats — the three-rung scratch-base ladder.
#
# Every rung case asserts BOTH halves: the source word through
# assert_explain_source, and the resolved ABSOLUTE path through
# svr_assert_workdir. The word alone is not acceptance — a base anchored to $PWD
# instead of to the profile's directory carries the right word over the wrong
# path, and that is precisely the surprising-location failure the ladder exists
# to prevent.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	source "${REPO_ROOT}/tests/helpers/short-video-fixtures.bash"
	SVR="${REPO_ROOT}/plugins/short-video-reader/scripts/short-video-read.sh"

	setup_tmp
	svr_home
	seed_base_utils
	seed_toolchain_stubs

	# The OS-temp rung under test must be a directory this suite owns, not the
	# executor's real temp dir: the default-rung cases assert the exact value.
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
# stub directory alone for that invocation — never prepends, and never stubs jq.
# See the helper for why the replacement belongs to the invocation rather than
# to this shell.

# ------------------------------------------------------------- the three rungs

@test "profile rung: the base comes from the profile, anchored to the profile's directory" {
	root="$(make_profile_fixture)"
	cd "${root}"

	svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_source "${output}" workdir profile
	svr_assert_workdir "${output}" "$(svr_phys "${root}")/scratch/short-video"
	[ "$(printf '%s' "${output}" | jq -r '.profile_file')" = "$(svr_phys "${root}")/.short-video-reader.json" ]
}

@test "env rung: an absolute SHORT_VIDEO_DIR is used as given" {
	root="$(make_bare_fixture)"
	base="${TMP}/env-base"
	cd "${root}"

	SHORT_VIDEO_DIR="${base}" svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_source "${output}" workdir detected:env
	svr_assert_workdir "${output}" "${base}"
}

@test "env rung: a relative SHORT_VIDEO_DIR anchors to \$PWD, not to a profile" {
	root="$(make_bare_fixture)"
	cd "${root}"

	SHORT_VIDEO_DIR="relative-scratch" svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_source "${output}" workdir detected:env
	svr_assert_workdir "${output}" "$(svr_phys "${root}")/relative-scratch"
}

@test "default rung: no profile above is a user with no project, never an error" {
	root="$(make_bare_fixture)"
	cd "${root}"

	svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_source "${output}" workdir default
	svr_assert_workdir "${output}" "${TMPDIR}/short-video-reader"
	[ "$(printf '%s' "${output}" | jq -r '.profile_file')" = "null" ]
}

@test "default rung: the OS temp dir is NAMESPACED, never handed over bare" {
	root="$(make_bare_fixture)"
	cd "${root}"

	svr_run "${SVR}" --explain
	assert_status 0
	workdir="$(printf '%s' "${output}" | jq -r '.values.workdir')"
	case "${workdir}" in
	*/short-video-reader) ;;
	*)
		printf 'the default base does not end in short-video-reader: %s\n' "${workdir}" >&2
		return 1
		;;
	esac
	[ "${workdir}" != "${TMPDIR}" ]
	[ "${workdir}" != "${TMPDIR}/" ]
}

# -------------------------------------------------------------- the precedence

@test "the environment outranks a committed profile, so a one-off run needs no edit" {
	root="$(make_profile_fixture)"
	base="${TMP}/override-base"
	cd "${root}"

	SHORT_VIDEO_DIR="${base}" svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_source "${output}" workdir detected:env
	svr_assert_workdir "${output}" "${base}"
}

# ---------------------------------------------------------------- the walk-up

@test "the walk-up finds a profile two directories above the cwd" {
	root="$(make_profile_fixture)"
	cd "${root}/nested/deeper"

	svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_source "${output}" workdir profile
	svr_assert_workdir "${output}" "$(svr_phys "${root}")/scratch/short-video"
}

@test "the walk-up passes THROUGH a repository toplevel rather than stopping at it" {
	# The builder needs git; the reader must never see it. svr_run hands the
	# invocation a PATH without it, which is what makes this case mean something:
	# no repository boundary can participate in a discovery that cannot run git.
	root="$(make_nested_git_fixture)"
	[ -d "${root}/nested/.git" ]
	cd "${root}/nested/deeper"

	svr_run "${SVR}" --explain
	assert_status 0
	assert_explain_source "${output}" workdir profile
	svr_assert_workdir "${output}" "$(svr_phys "${root}")/scratch/short-video"
}

@test "a relative workdir answers with ONE path from every cwd under the profile" {
	root="$(make_profile_fixture)"

	cd "${root}"
	svr_run "${SVR}" --explain
	assert_status 0
	from_root="$(printf '%s' "${output}" | jq -r '.values.workdir')"

	cd "${root}/nested/deeper"
	svr_run "${SVR}" --explain
	assert_status 0
	from_nested="$(printf '%s' "${output}" | jq -r '.values.workdir')"

	if [ "${from_root}" != "${from_nested}" ]; then
		printf 'the base moved with the cwd: %s from the profile dir, %s from nested/deeper\n' \
			"${from_root}" "${from_nested}" >&2
		return 1
	fi
	[ "${from_root}" = "$(svr_phys "${root}")/scratch/short-video" ]
}

# ------------------------------------------------------------- the usage error

@test "an unreadable profile is a usage error, never a fall-through to the next rung" {
	root="$(make_malformed_fixture)"
	cd "${root}"

	svr_run "${SVR}" --explain
	assert_status 2
	assert_contains "${output}" "profile is not readable JSON"
	assert_not_contains "${output}" '"plugin"' # nothing resolved, so nothing was printed
}

# --------------------------------------------------- one resolver, all consumers

@test "the base, the delete guard and --zoom all follow the environment override in one run" {
	root="$(make_bare_fixture)"
	base="${TMP}/moved-base"
	video="${root}/clip.mp4"
	printf 'short-video-reader fixture artifact — not a real media file\n' >"${video}"
	cd "${root}"
	export SHORT_VIDEO_DIR="${base}"

	svr_run "${SVR}" "${video}" --slug moved
	assert_status 0
	run_dir="${base}/moved"
	[ -d "${run_dir}" ]
	assert_contains "${output}" "run dir     ${run_dir}"

	# --zoom writes into the moved run directory and hands back an openable path.
	svr_run "${SVR}" --zoom "${run_dir}" 3
	assert_status 0
	[ -r "${output}" ]

	# The guard refuses a directory outside the moved base...
	outside="${TMP}/not-the-base"
	mkdir -p "${outside}"
	svr_run "${SVR}" --remove-tmp "${outside}"
	assert_status 2
	assert_contains "${output}" "${base}"
	[ -d "${outside}" ]

	# ...and accepts the run directory inside it.
	svr_run "${SVR}" --remove-tmp "${run_dir}"
	assert_status 0
	[ ! -d "${run_dir}" ]
}
