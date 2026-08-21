#!/usr/bin/env bats
#
# tests/test-toolsmith-exact.bats
#
# The skill finder's --exact mode is the collision check every authoring flow
# runs before it writes a file, so it has two ways to be worse than useless.
#
#   1. A declared name is written the way it is INVOKED — `/man`,
#      `/toolsmith:create` — while the needle is bare. Compared raw, an owned
#      name reads as free. The decoy fixture declares both spellings.
#   2. The remote tier is where the ecosystem's names live, so an exact check
#      that returns before reaching it answers the easy half of the question
#      and calls it the answer.
#
# Both are driven here rather than grepped: the finder has a real CLI boundary.

setup_file() {
	export FIXROOT="${BATS_FILE_TMPDIR}/fixtures"
	mkdir -p "${FIXROOT}"
	bash "${BATS_TEST_DIRNAME}/fixtures/toolsmith/setup.sh" "${FIXROOT}" >/dev/null
}

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	command -v bun >/dev/null 2>&1 || skip "bun is not installed"
	FS="${REPO_ROOT}/plugins/toolsmith/scripts/find-skill.sh"
	DECOY="${FIXROOT}/decoy-repo"
	PLAIN="${FIXROOT}/plain-agent"
}

teardown() { teardown_tmp; }

# A `gh search code` result naming one skill, so the remote tier has something
# to find without a network call.
stub_gh_hit() {
	cat >"${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf '[{"repository":{"nameWithOwner":"acme/manuals"},"path":"skills/man/SKILL.md"}]'
EOF
	chmod +x "${STUB_BIN}/gh"
}

# skills.sh is reached over HTTP; pointing it at a closed port makes the tier
# report an honest note instead of hanging on the network.
offline_skills_sh() {
	export SKILLS_API_URL="http://127.0.0.1:9"
}

# ------------------------------------------------------- the declared name ---

@test "toolsmith exact: --exact man reports TAKEN against a decoy declaring /man" {
	run bash "${FS}" --exact man --root "${DECOY}" --tier project
	assert_status 0
	assert_contains "${output}" "NAME TAKEN"
	assert_contains "${output}" "/man"
}

@test "toolsmith exact: a category prefix is stripped from both sides before they meet" {
	run bash "${FS}" --exact create --root "${DECOY}" --tier project
	assert_status 0
	assert_contains "${output}" "NAME TAKEN"
	assert_contains "${output}" "/toolsmith:create"
}

@test "toolsmith exact: the file on disk answers too, not only the declared name" {
	# manual.md declares /man; the file basename is the other spelling a caller
	# may write, and it must clash just the same.
	run bash "${FS}" --exact manual --root "${DECOY}" --tier project
	assert_status 0
	assert_contains "${output}" "NAME TAKEN"
}

@test "toolsmith exact: a name nothing declares is still reported free" {
	run bash "${FS}" --exact nothing-declares-this --root "${DECOY}" --tier project
	assert_status 0
	assert_contains "${output}" "NAME FREE"
}

# ---------------------------------------------------------- the remote tier --

@test "toolsmith exact: --exact with --remote reaches the remote tier" {
	stub_gh_hit
	offline_skills_sh
	run bash "${FS}" --exact man --root "${PLAIN}" --tier remote --remote --json
	assert_status 0
	# The clash can only have come from the remote tier: no local tier ran.
	[ "$(printf '%s' "${output}" | jq -r '.clashes | length')" -ge 1 ]
	[ "$(printf '%s' "${output}" | jq -r '.clashes[0].tier')" = "remote" ]
	[ "$(printf '%s' "${output}" | jq -r '.clashes[0].origin')" = "acme/manuals" ]
}

@test "toolsmith exact: a locally free name is NOT reported free once the remote tier owns it" {
	stub_gh_hit
	offline_skills_sh
	# The plain fixture declares no `man` anything, so the local answer is free.
	run bash "${FS}" --exact man --root "${PLAIN}" --tier project
	assert_status 0
	assert_contains "${output}" "NAME FREE"

	run bash "${FS}" --exact man --root "${PLAIN}" --remote
	assert_status 0
	assert_contains "${output}" "NAME TAKEN"
	assert_contains "${output}" "acme/manuals"
}

@test "toolsmith exact: an unreachable remote tier is a note, never a silent free verdict" {
	unstub gh
	offline_skills_sh
	run bash "${FS}" --exact man --root "${PLAIN}" --tier remote --remote
	assert_status 0
	assert_contains "${output}" "note:"
	assert_contains "${output}" "skills.sh"
}

# ------------------------------------------------------------ the layout ----

@test "toolsmith exact: the project tier walks the dirs the adapter names" {
	# The decoy is a rulesync-shaped project; the same needle against a plain
	# one must miss, which it can only do by reading the right directory.
	run bash "${FS}" --exact man --root "${DECOY}" --tier project
	assert_contains "${output}" "NAME TAKEN"
	run bash "${FS}" --exact man --root "${PLAIN}" --tier project
	assert_contains "${output}" "NAME FREE"
}

@test "toolsmith exact: an unmarked directory drops the project tier with a note, not a crash" {
	run bash "${FS}" --exact man --root "${FIXROOT}/unmarked" --tier project
	assert_status 0
	assert_contains "${output}" "NAME FREE"
	assert_contains "${output}" "project tier skipped"
}

@test "toolsmith exact: a layout with no staged-plugin registry says so rather than reporting none" {
	run bash "${FS}" notekeeper --root "${PLAIN}" --tier project
	assert_status 0
	assert_contains "${output}" "staged-plugins tier not applicable"

	run bash "${FS}" pdf --root "${FIXROOT}/rulesync-layout" --tier project
	assert_status 0
	assert_not_contains "${output}" "staged-plugins tier not applicable"
}
