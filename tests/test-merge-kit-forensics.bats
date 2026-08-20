#!/usr/bin/env bats
#
# tests/test-merge-kit-forensics.bats
#
# merge-forensics.sh is driven against four real repository states, one per
# mode it claims to handle. The states are produced by running the operations
# — a merge that conflicts, a rebase that stops — because the shape of the
# state directory is exactly what the script reads, and a hand-written
# MERGE_HEAD would test the fixture rather than the tool.
#
# The squash fixture carries a genuine silent reversion: the squashed content
# is the source branch's file verbatim, so the line the target gained after the
# fork is gone. A forensic tool that cannot see that one has no reason to run.

setup_file() {
	export FIXROOT="${BATS_FILE_TMPDIR}/forensics"
	mkdir -p "${FIXROOT}"
	bash "${BATS_TEST_DIRNAME}/fixtures/merge-kit/forensics-setup.sh" "${FIXROOT}" >/dev/null
}

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	MF="${REPO_ROOT}/plugins/merge-kit/scripts/merge-forensics.sh"
}

teardown() { teardown_tmp; }

json() { printf '%s' "${output}" | jq -r "$1"; }

# ------------------------------------------------------------ mode: merge ----

@test "merge-forensics: a finished two-parent merge that reverts nothing is CLEAN" {
	run bash "${MF}" --repo "${FIXROOT}/clean-merge" HEAD
	assert_status 0
	[ "$(json .mode)" = "merge" ]
	[ "$(json .verdict)" = "CLEAN" ]
	[ "$(json '.at_risk | length')" = "0" ]
	[ "$(json '.lost_lines | length')" = "0" ]
}

@test "merge-forensics: a two-parent merge takes its fork point from the graph" {
	local repo="${FIXROOT}/clean-merge" expected_fork expected_pre
	expected_fork="$(git -C "${repo}" merge-base HEAD^1 HEAD^2)"
	expected_pre="$(git -C "${repo}" rev-parse HEAD^1)"
	run bash "${MF}" --repo "${repo}" HEAD
	assert_status 0
	[ "$(json .fork)" = "${expected_fork}" ]
	[ "$(json .pre)" = "${expected_pre}" ]
	[ "$(json .post)" = "$(git -C "${repo}" rev-parse HEAD)" ]
}

# ----------------------------------------------------------- mode: squash ----

@test "merge-forensics: a one-parent squash with no fork point exits 2 and says how to fix it" {
	local repo="${FIXROOT}/squash-merge" squash
	squash="$(git -C "${repo}" rev-parse main)"
	run bash "${MF}" --repo "${repo}" "${squash}"
	assert_status 2
	assert_contains "${output}" "squash merge: pass --fork or --source"
}

@test "merge-forensics: --source recovers the fork point and exposes the dropped target line" {
	local repo="${FIXROOT}/squash-merge"
	run bash "${MF}" --repo "${repo}" main --source feature
	assert_status 0
	[ "$(json .mode)" = "squash" ]
	[ "$(json .verdict)" = "FINDINGS" ]
	[ "$(json '.at_risk | join(",")')" = "shared.txt" ]
	[ "$(json '.lost_lines[0].file')" = "shared.txt" ]
	[ "$(json '.lost_lines[0].count')" = "1" ]
	assert_contains "$(json '.lost_lines[0].lines | join(",")')" "epsilon-from-target"
}

@test "merge-forensics: --fork names the fork point directly and reaches the same verdict" {
	local repo="${FIXROOT}/squash-merge" fork
	fork="$(git -C "${repo}" merge-base main feature)"
	run bash "${MF}" --repo "${repo}" main --fork "${fork}"
	assert_status 0
	[ "$(json .fork)" = "${fork}" ]
	[ "$(json .verdict)" = "FINDINGS" ]
}

@test "merge-forensics: the clean merge is not reported as a squash" {
	# The one-parent guard must key off the parent count, not off the absence
	# of --source, or every merge would demand a fork point.
	run bash "${MF}" --repo "${FIXROOT}/clean-merge" HEAD
	assert_status 0
	assert_not_contains "${output}" "squash"
}

# ------------------------------------------------------ mode: in progress ----

@test "merge-forensics: --in-progress autodetects a conflicted merge from MERGE_HEAD" {
	local repo="${FIXROOT}/in-progress-merge"
	[ -f "${repo}/.git/MERGE_HEAD" ]
	run bash "${MF}" --repo "${repo}" --in-progress
	assert_status 0
	[ "$(json .mode)" = "in-progress-merge" ]
	[ "$(json .post)" = "WORKTREE" ]
	[ "$(json .pre)" = "$(git -C "${repo}" rev-parse HEAD)" ]
	[ "$(json .fork)" = "$(git -C "${repo}" merge-base HEAD MERGE_HEAD)" ]
}

@test "merge-forensics: --in-progress autodetects a stopped rebase from its state directory" {
	local repo="${FIXROOT}/in-progress-rebase"
	[ -d "${repo}/.git/rebase-merge" ] || [ -d "${repo}/.git/rebase-apply" ]
	run bash "${MF}" --repo "${repo}" --in-progress
	assert_status 0
	[ "$(json .mode)" = "in-progress-rebase" ]
	[ "$(json .post)" = "WORKTREE" ]
	# PRE is the recorded onto ref — during a rebase HEAD is a replayed commit,
	# so reading HEAD would measure against the wrong target.
	[ "$(json .pre)" = "$(git -C "${repo}" rev-parse main)" ]
}

@test "merge-forensics: the in-progress modes read the worktree, so a resolution changes the answer" {
	local repo="${TMP}/live-merge"
	cp -R "${FIXROOT}/in-progress-merge" "${repo}"
	run bash "${MF}" --repo "${repo}" --in-progress
	assert_status 0
	[ "$(json '.at_risk | join(",")')" = "shared.txt" ]
	[ "$(json .verdict)" = "CLEAN" ]

	# Resolving to the source side alone drops the line the target added.
	printf 'alpha\nbeta-from-feature\ngamma\n' >"${repo}/shared.txt"
	run bash "${MF}" --repo "${repo}" --in-progress
	assert_status 0
	[ "$(json .verdict)" = "FINDINGS" ]
	assert_contains "$(json '.lost_lines[0].lines | join(",")')" "beta-from-target"
}

@test "merge-forensics: --in-progress with nothing in progress exits 2" {
	run bash "${MF}" --repo "${FIXROOT}/clean-merge" --in-progress
	assert_status 2
	assert_contains "${output}" "no merge or rebase in progress"
}

# ------------------------------------------------------------ the interface --

@test "merge-forensics: --repo is mandatory" {
	run bash "${MF}" HEAD
	assert_status 2
	assert_contains "${output}" "--repo"
}

@test "merge-forensics: --repo must point at a git repository" {
	mkdir -p "${TMP}/plain"
	run bash "${MF}" --repo "${TMP}/plain" HEAD
	assert_status 2
	assert_contains "${output}" "not a git repository"

	run bash "${MF}" --repo "${TMP}/does-not-exist" HEAD
	assert_status 2
	assert_contains "${output}" "no such directory"
}

@test "merge-forensics: a commit and --in-progress together is a usage error" {
	run bash "${MF}" --repo "${FIXROOT}/clean-merge" HEAD --in-progress
	assert_status 2
	assert_contains "${output}" "not both"
}

@test "merge-forensics: an unknown commit is refused rather than analysed against nothing" {
	run bash "${MF}" --repo "${FIXROOT}/clean-merge" deadbeefdeadbeef
	assert_status 2
	assert_contains "${output}" "not a commit"
}

@test "merge-forensics: every mode prints one valid JSON object naming its three references" {
	local repo
	for repo in clean-merge in-progress-merge in-progress-rebase; do
		if [ "${repo}" = "clean-merge" ]; then
			run bash "${MF}" --repo "${FIXROOT}/${repo}" HEAD
		else
			run bash "${MF}" --repo "${FIXROOT}/${repo}" --in-progress
		fi
		assert_status 0
		printf '%s' "${output}" | jq -e '
            has("repo") and has("mode") and has("fork") and has("pre")
            and has("post") and has("verdict")
            and (.fork | test("^[0-9a-f]{40}$"))
            and (.pre | test("^[0-9a-f]{40}$"))
        ' >/dev/null
	done
}
