#!/usr/bin/env bats
#
# tests/test-short-video-guard.bats — the delete guard and the ownership proof
# it rests on.
#
# The guard's job is not "delete carefully under the base". The base is whatever
# SHORT_VIDEO_DIR or a committed profile said it was, so "under the base" is a
# claim the CALLER supplies — and a caller who points the reader at a directory
# that already holds work gets that work deleted. Every case here is about the
# second condition: the target must PROVE the reader created it, by carrying
# .short-video-reader-run with the magic string inside.
#
# Two directions, and the suite covers both. As a delete target a stranger's
# directory must be refused; as a RUN target it must be refused too, because
# adopting it — planting a marker into whatever was already standing there — is
# how it would become deletable a moment later.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	source "${REPO_ROOT}/tests/helpers/short-video-fixtures.bash"
	SVR="${REPO_ROOT}/plugins/short-video-reader/scripts/short-video-read.sh"

	setup_tmp
	svr_home
	seed_base_utils
	seed_toolchain_stubs

	# The default rung must land in a directory this suite owns: a refusal case
	# that fell through to the executor's real temp dir would be asserting
	# against whatever else lives there.
	TMPDIR="${TMP}/ostemp"
	mkdir -p "${TMPDIR}"
	export TMPDIR

	unset SHORT_VIDEO_DIR SHORT_VIDEO_WHISPER_MODEL
}

teardown() {
	# hash -r AFTER the delete — see the workdir suite for why bats itself
	# breaks without it.
	teardown_tmp
	hash -r
}

# make_clip <dir> — the local-file input every run case here uses. A local file
# keeps yt-dlp out of the picture: the guard has nothing to do with acquisition.
make_clip() {
	local f="${1}/clip.mp4"
	printf 'short-video-reader fixture artifact — not a real media file\n' >"${f}"
	printf '%s\n' "${f}"
}

# --------------------------------------------------------- the ownership proof

@test "a real run directory carries the marker at creation and is accepted for deletion" {
	root="$(make_bare_fixture)"
	clip="$(make_clip "${root}")"
	base="${TMP}/owned-base"
	cd "${root}"
	export SHORT_VIDEO_DIR="${base}"

	svr_run "${SVR}" "${clip}" --slug owned
	assert_status 0
	run_dir="${base}/owned"

	# The marker is written at CREATION, not at report time: this is what makes
	# a run that dies halfway still recognisable, and still deletable.
	[ -f "${run_dir}/${SVR_RUN_MARKER}" ]
	assert_contains "$(cat "${run_dir}/${SVR_RUN_MARKER}")" "${SVR_RUN_MAGIC}"

	svr_run "${SVR}" --remove-tmp "${run_dir}"
	assert_status 0
	assert_contains "${output}" "removed"
	[ ! -e "${run_dir}" ]
}

@test "a directory under the base holding only a report.json is REFUSED and survives" {
	root="$(make_bare_fixture)"
	base="${TMP}/foreign-base"
	mkdir -p "${base}"
	foreign="$(make_foreign_dir "${base}")"
	cd "${root}"
	export SHORT_VIDEO_DIR="${base}"

	svr_run "${SVR}" --remove-tmp "${foreign}"
	assert_status 2
	# The refusal says what it looked for, so the operator learns the rule from
	# the message rather than from the exit code.
	assert_contains "${output}" "${SVR_RUN_MARKER}"
	assert_contains "${output}" "${SVR_RUN_MAGIC}"
	assert_contains "${output}" "${base}"
	assert_contains "${output}" "detected:env"

	[ -d "${foreign}" ]
	[ -f "${foreign}/report.json" ]
}

@test "a re-run REUSES a directory that carries the marker, since it is our own earlier run" {
	root="$(make_bare_fixture)"
	clip="$(make_clip "${root}")"
	base="${TMP}/rerun-base"
	cd "${root}"
	export SHORT_VIDEO_DIR="${base}"

	svr_run "${SVR}" "${clip}" --slug repeated
	assert_status 0
	run_dir="${base}/repeated"
	printf 'from the first run\n' >"${run_dir}/first-run.txt"

	svr_run "${SVR}" "${clip}" --slug repeated
	assert_status 0
	[ -f "${run_dir}/first-run.txt" ]
	[ -f "${run_dir}/report.json" ]
}

# ------------------------------------------------------- the collision as a run

@test "a PRE-EXISTING foreign directory is REFUSED as a run target and left untouched" {
	root="$(make_bare_fixture)"
	clip="$(make_clip "${root}")"
	base="${TMP}/collision-base"
	mkdir -p "${base}"
	foreign="$(make_foreign_dir "${base}" collide)"
	before="$(cat "${foreign}/report.json")"
	cd "${root}"
	export SHORT_VIDEO_DIR="${base}"

	svr_run "${SVR}" "${clip}" --slug collide
	assert_status 2
	assert_contains "${output}" "collide"
	assert_contains "${output}" "${SVR_RUN_MARKER}"

	# Nothing planted, nothing overwritten, no run tree grafted on top: the
	# adoption this refusal prevents is exactly what would make the stranger's
	# directory deletable by the next --remove-tmp.
	[ ! -e "${foreign}/${SVR_RUN_MARKER}" ]
	[ ! -d "${foreign}/media" ]
	[ ! -d "${foreign}/frames" ]
	[ "$(cat "${foreign}/report.json")" = "${before}" ]
}

# ---------------------------------------------------------- the base sanity net

@test "a resolved base of / is REFUSED with the rung named" {
	root="$(make_bare_fixture)"
	cd "${root}"

	SHORT_VIDEO_DIR="/" svr_run "${SVR}" --explain
	assert_status 2
	assert_contains "${output}" "detected:env"
	assert_contains "${output}" "filesystem root"
	assert_not_contains "${output}" '"plugin"' # nothing resolved, so nothing printed
}

@test "a resolved base of \$HOME is REFUSED with the rung named" {
	root="$(make_bare_fixture)"
	cd "${root}"

	SHORT_VIDEO_DIR="${HOME}" svr_run "${SVR}" --explain
	assert_status 2
	assert_contains "${output}" "detected:env"
	assert_contains "${output}" "home directory"
}

@test "the rung named in a base refusal is the rung that produced the base" {
	# The same refusal, reached from the profile rung instead of the
	# environment: the path is the symptom, the rung is what has to be fixed.
	root="$(make_bare_fixture profile-root-base)"
	write_profile "${root}" '{"workdir": "/"}' >/dev/null
	cd "${root}"

	svr_run "${SVR}" --explain
	assert_status 2
	assert_contains "${output}" "profile"
	assert_contains "${output}" "filesystem root"
	assert_not_contains "${output}" "detected:env"
}

@test "a resolved base that is a repository checkout is REFUSED" {
	root="$(make_bare_fixture)"
	checkout="${TMP}/a-checkout"
	make_git_repo "${checkout}"
	cd "${root}"

	SHORT_VIDEO_DIR="${checkout}" svr_run "${SVR}" --explain
	assert_status 2
	assert_contains "${output}" "detected:env"
	assert_contains "${output}" "repository checkout"
}

# ------------------------------------------------- containment, independently

@test "a path outside the resolved base is refused and nothing is removed" {
	root="$(make_bare_fixture)"
	clip="$(make_clip "${root}")"
	# The OLD literal scratch location, which earlier versions of this tool
	# hard-coded: a run made there is genuinely ours, marker and all.
	old_base="${TMP}/oldtree/tmp/short-video"
	cd "${root}"

	SHORT_VIDEO_DIR="${old_base}" svr_run "${SVR}" "${clip}" --slug legacy
	assert_status 0
	legacy="${old_base}/legacy"
	[ -f "${legacy}/${SVR_RUN_MARKER}" ]

	# A different base is resolved now. Ownership holds and containment does
	# not, and the guard needs BOTH — so the legacy run survives.
	base="${TMP}/current-base"
	export SHORT_VIDEO_DIR="${base}"
	svr_run "${SVR}" --remove-tmp "${legacy}"
	assert_status 2
	assert_contains "${output}" "outside the resolved base"
	assert_contains "${output}" "${base}"
	assert_contains "${output}" "detected:env"
	[ -d "${legacy}" ]
	[ -f "${legacy}/report.json" ]

	# A stray directory outside the base owns nothing either way.
	outside="${TMP}/not-the-base"
	mkdir -p "${outside}"
	printf 'somebody else\n' >"${outside}/keepme.txt"
	svr_run "${SVR}" --remove-tmp "${outside}"
	assert_status 2
	[ -f "${outside}/keepme.txt" ]
}
