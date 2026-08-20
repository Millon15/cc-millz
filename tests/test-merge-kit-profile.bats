#!/usr/bin/env bats
#
# tests/test-merge-kit-profile.bats
#
# merge-kit.sh has a real CLI boundary, so its contract is driven rather than
# grepped. Every case asserts the VALUE and the SOURCE through
# assert_explain_source: a repo map that happens to be right because the tool
# guessed, or a test command that is right for the wrong rung, is a bug that
# would otherwise pass.
#
# The fixture repos are built once per file into BATS_FILE_TMPDIR — a git repo
# cannot be committed inside another git repo, so tests/fixtures/merge-kit/
# ships plain files and setup.sh turns them into repos with real remotes here.

setup_file() {
	export FIXROOT="${BATS_FILE_TMPDIR}/fixtures"
	mkdir -p "${FIXROOT}"
	bash "${BATS_TEST_DIRNAME}/fixtures/merge-kit/setup.sh" "${FIXROOT}" >/dev/null
}

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	PLUGIN="${REPO_ROOT}/plugins/merge-kit"
	MK="${PLUGIN}/scripts/merge-kit.sh"
	FIXTURES="${REPO_ROOT}/tests/fixtures/merge-kit"
	WORKSPACE="${FIXROOT}/workspace"
	PROFILED="${FIXROOT}/profile-workspace"
}

teardown() { teardown_tmp; }

# ------------------------------------------------------------- the package --

@test "merge-kit: the plugin manifest is 0.1.0 with an empty dependencies field" {
	run jq -r '.name, .version' "${PLUGIN}/.claude-plugin/plugin.json"
	assert_status 0
	assert_contains "${output}" "merge-kit"
	assert_contains "${output}" "0.1.0"
	[ "$(jq -r '.dependencies | length' "${PLUGIN}/.claude-plugin/plugin.json")" = "0" ]
}

@test "merge-kit: both entry scripts are executable" {
	[ -x "${MK}" ]
	[ -x "${PLUGIN}/scripts/merge-forensics.sh" ]
}

@test "merge-kit: an invocation without --explain is a usage error, not a default run" {
	run bash "${MK}" --root "${WORKSPACE}"
	assert_status 2
	assert_contains "${output}" "--explain"
}

# ------------------------------------------------------- profile precedence --

@test "merge-kit: with no profile the repo map comes from the origin scan" {
	run bash "${MK}" --explain --root "${WORKSPACE}"
	assert_status 0
	assert_explain_source "${output}" repos detected:origin-scan
	[ "$(printf '%s' "${output}" | jq -r '.profile_file')" = "null" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.repos["node-repo"]')" = "node-repo" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.repos["workspace"]')" = "." ]
}

@test "merge-kit: a profile beats the scan — its aliases win, and the scan's do not appear" {
	run bash "${MK}" --explain --root "${PROFILED}"
	assert_status 0
	assert_explain_source "${output}" repos profile
	[ "$(printf '%s' "${output}" | jq -r '.values.repos.node')" = "node-repo" ]
	# The scan would have produced these aliases; the profile means it never ran.
	[ "$(printf '%s' "${output}" | jq -r '.values.repos["node-repo"] // "absent"')" = "absent" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.repos["quiet-repo"] // "absent"')" = "absent" ]
}

@test "merge-kit: the profile is found by walking up from a subdirectory" {
	run bash "${MK}" --explain --root "${PROFILED}/node-repo"
	assert_status 0
	assert_explain_source "${output}" repos profile
	assert_contains "$(printf '%s' "${output}" | jq -r '.profile_file')" ".merge-kit.json"
}

@test "merge-kit: work_dir comes from the profile, and defaults without one" {
	run bash "${MK}" --explain --root "${PROFILED}"
	assert_status 0
	assert_explain_source "${output}" work_dir profile
	[ "$(printf '%s' "${output}" | jq -r '.values.work_dir')" = "tmp/merge-kit-work" ]

	run bash "${MK}" --explain --root "${WORKSPACE}"
	assert_status 0
	assert_explain_source "${output}" work_dir default
	[ "$(printf '%s' "${output}" | jq -r '.values.work_dir')" = "tmp/merge-kit" ]
}

@test "merge-kit: an unreadable profile exits 2 rather than falling back to detection" {
	run bash "${MK}" --explain --root "${FIXROOT}/bad-profile"
	assert_status 2
	assert_contains "${output}" "not readable JSON"
}

@test "merge-kit: a directory with nothing to detect exits 2 naming the markers" {
	run bash "${MK}" --explain --root "${FIXROOT}/no-git"
	assert_status 2
	assert_contains "${output}" ".merge-kit.json"
	assert_contains "${output}" "'origin' remote"
}

@test "merge-kit: an ordinary subdirectory of a checkout is not mistaken for a repo" {
	# `git -C <dir>` answers from the enclosing repository, so a plain
	# subdirectory reports that repository's remote unless the scan checks
	# that the directory IS the repo root.
	mkdir -p "${WORKSPACE}/node-repo/src/inner"
	run bash "${MK}" --explain --root "${WORKSPACE}/node-repo/src"
	assert_status 2
	assert_contains "${output}" "nothing to work with"
}

# ------------------------------------------------------------- the forge -----

@test "merge-kit: the forge is reported as detected:origin-url, never as profile" {
	run bash "${MK}" --explain --root "${WORKSPACE}"
	assert_status 0
	assert_explain_source "${output}" forge detected:origin-url

	run bash "${MK}" --explain --root "${PROFILED}" --repo node
	assert_status 0
	assert_explain_source "${output}" forge detected:origin-url
}

@test "merge-kit: a forge key placed in the profile is IGNORED, not honoured" {
	# The fixture profile sets every forge to a value no detector can produce.
	grep -q 'IGNORED-forge-key' "${PROFILED}/.merge-kit.json"

	run bash "${MK}" --explain --root "${PROFILED}"
	assert_status 0
	assert_not_contains "${output}" "IGNORED-forge-key"
	[ "$(printf '%s' "${output}" | jq -r '.values.forge.node')" = "gh" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.forge.go')" = "bbkt" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.forge.make')" = "glab" ]
}

@test "merge-kit: every origin URL in the truth table resolves to its CLI" {
	local n=0 url want got dir
	while read -r url want; do
		case "${url}" in '#'* | '') continue ;; esac
		n=$((n + 1))
		dir="${TMP}/forge-${n}"
		make_git_repo "${dir}"
		git -C "${dir}" remote add origin "${url}"
		got="$(bash "${MK}" --explain --root "${dir}" | jq -r '.values.forge[]')"
		if [ "${want}" = "-" ]; then want=null; fi
		if [ "${got}" != "${want}" ]; then
			printf '%s resolved to %s, expected %s\n' "${url}" "${got}" "${want}" >&2
			return 1
		fi
	done <"${FIXTURES}/origin-urls.txt"
	[ "${n}" -ge 7 ]
}

# ------------------------------------------------------- the test command ----

@test "merge-kit: test_command appears only when the answer is scoped to one repo" {
	run bash "${MK}" --explain --root "${WORKSPACE}"
	assert_status 0
	# A single source word cannot be honest about repos landing on different
	# rungs, so the project-wide answer does not claim one.
	[ "$(printf '%s' "${output}" | jq -r '.values | has("test_command")')" = "false" ]
	[ "$(printf '%s' "${output}" | jq -r '.sources | has("test_command")')" = "false" ]
}

@test "merge-kit: rung 1 — a profile override wins over every detectable rung" {
	run bash "${MK}" --explain --root "${PROFILED}" --repo go
	assert_status 0
	assert_explain_source "${output}" test_command profile
	[ "$(printf '%s' "${output}" | jq -r '.values.test_command.go')" = "go test ./... -race" ]
}

@test "merge-kit: rung 2 — a Makefile test target beats a package.json test script" {
	# make-repo carries both; the rung order is what decides.
	[ -f "${WORKSPACE}/make-repo/package.json" ]
	run bash "${MK}" --explain --root "${WORKSPACE}" --repo make-repo
	assert_status 0
	assert_explain_source "${output}" test_command detected:makefile
	[ "$(printf '%s' "${output}" | jq -r '.values.test_command["make-repo"]')" = "make test" ]
}

@test "merge-kit: rung 3 — a package.json test script, with the runner off the lockfile" {
	run bash "${MK}" --explain --root "${WORKSPACE}" --repo node-repo
	assert_status 0
	assert_explain_source "${output}" test_command detected:package-json
	[ "$(printf '%s' "${output}" | jq -r '.values.test_command["node-repo"]')" = "npm test" ]

	cp -R "${WORKSPACE}/node-repo" "${TMP}/yarn-repo"
	touch "${TMP}/yarn-repo/yarn.lock"
	run bash "${MK}" --explain --root "${TMP}" --repo yarn-repo
	assert_status 0
	assert_explain_source "${output}" test_command detected:package-json
	[ "$(printf '%s' "${output}" | jq -r '.values.test_command["yarn-repo"]')" = "yarn test" ]
}

@test "merge-kit: rung 4 — a language default when there is no build script at all" {
	run bash "${MK}" --explain --root "${WORKSPACE}" --repo go-repo
	assert_status 0
	assert_explain_source "${output}" test_command detected:go-mod
	[ "$(printf '%s' "${output}" | jq -r '.values.test_command["go-repo"]')" = "go test ./..." ]
}

@test "merge-kit: the honest degrade — nothing detectable reports null, not a guess" {
	run bash "${MK}" --explain --root "${WORKSPACE}" --repo quiet-repo
	assert_status 0
	assert_explain_source "${output}" test_command default
	[ "$(printf '%s' "${output}" | jq -r '.values.test_command["quiet-repo"]')" = "null" ]
	# A repo on a host with no CLI degrades the same way rather than guessing one.
	assert_explain_source "${output}" forge detected:origin-url
	[ "$(printf '%s' "${output}" | jq -r '.values.forge["quiet-repo"]')" = "null" ]
}

# ------------------------------------------------------------- the scoping --

@test "merge-kit: --repo accepts the path as well as the alias" {
	run bash "${MK}" --explain --root "${PROFILED}" --repo node-repo
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.repos | keys | join(",")')" = "node" ]
}

@test "merge-kit: an unknown --repo exits 2 and lists what it does know" {
	run bash "${MK}" --explain --root "${PROFILED}" --repo nope
	assert_status 2
	assert_contains "${output}" "unknown repo: nope"
	assert_contains "${output}" "node"
}

# ------------------------------------------------------------ the contract --

@test "merge-kit: every values key is mirrored in sources, scoped and unscoped" {
	run bash "${MK}" --explain --root "${WORKSPACE}"
	assert_status 0
	assert_explain_complete "${output}"
	[ "$(printf '%s' "${output}" | jq -r '.plugin')" = "merge-kit" ]

	run bash "${MK}" --explain --root "${PROFILED}" --repo make
	assert_status 0
	assert_explain_complete "${output}"
}

@test "merge-kit: --explain has no side effects on the repo it reads" {
	local before after
	before="$(git -C "${WORKSPACE}/node-repo" status --porcelain)"
	run bash "${MK}" --explain --root "${WORKSPACE}" --repo node-repo
	assert_status 0
	after="$(git -C "${WORKSPACE}/node-repo" status --porcelain)"
	[ "${before}" = "${after}" ]
	[ ! -e "${WORKSPACE}/tmp" ]
}
