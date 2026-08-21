#!/usr/bin/env bats
#
# tests/test-toolsmith-vendor.bats
#
# Vendoring copies someone else's skill into a project and commits it, so the
# two questions worth driving are WHERE the copy lands and WHETHER it should
# land at all.
#
#   WHERE — the skills directory and the provenance record are the layout's,
#           read off the adapter. The rewrite this port needed is exactly that:
#           the origin script wrote one hard-coded directory and one hard-coded
#           record file, and both fixtures here would have taken the other's.
#   WHETHER — a name an enabled plugin stages into the sources is refused,
#           because the next sync would delete the copy. That refusal only
#           exists in a layout that HAS a staged-plugin registry, which is one
#           more thing the adapter answers rather than the script assuming.
#
# Every run is offline: VENDOR_SKILL_GIT_BASE points git at a local fixture repo
# instead of a forge, so the suite needs no network and no credentials.

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
	command -v jq >/dev/null 2>&1 || skip "jq is not installed"
	VS="${REPO_ROOT}/plugins/toolsmith/scripts/vendor-skill.sh"
	export VENDOR_SKILL_GIT_BASE="${TMP}/remotes/"
}

teardown() { teardown_tmp; }

# project <fixture> — a private copy of a layout fixture; prints its path.
project() {
	local dest="${TMP}/proj-$1"
	[ -d "${dest}" ] || cp -R "${FIXROOT}/$1" "${dest}"
	printf '%s\n' "${dest}"
}

# seed_remote — a local repo at $TMP/remotes/acme/toolbox.git holding one skill.
seed_remote() {
	local repo="${TMP}/remotes/acme/toolbox.git"
	[ -d "${repo}" ] && return 0
	mkdir -p "${repo}/skills/widget-maker"
	printf -- '---\nname: widget-maker\ndescription: Use when making widgets from upstream sprockets\n---\n# Widget Maker\n\nUpstream body.\n' \
		>"${repo}/skills/widget-maker/SKILL.md"
	printf 'MIT License\n' >"${repo}/LICENSE"
	make_git_repo "${repo}"
	git -C "${repo}" add -A
	git -C "${repo}" commit --quiet -m "fixture"
}

# ---------------------------------------------------------------- the usage --

@test "toolsmith vendor: the script ships executable and syntactically valid" {
	[ -x "${VS}" ]
	run bash -n "${VS}"
	assert_status 0
}

@test "toolsmith vendor: no source prints usage and exits 0" {
	run bash "${VS}" --root "$(project plain-agent)"
	assert_status 0
	assert_contains "${output}" "usage: vendor-skill.sh"
	assert_contains "${output}" "owner/repo@skill"
}

@test "toolsmith vendor: the script names no directory of its own" {
	local body
	body="$(cat "${VS}")"
	assert_contains "${body}" "toolsmith.sh"
	assert_not_contains "${body}" "bin/claude/"
	assert_not_contains "${body}" "/Users/"
}

# ------------------------------------------------------------- the refusals --

@test "toolsmith vendor: an unparseable source is refused with exit 2" {
	run bash "${VS}" "not-a-source" --root "$(project plain-agent)"
	assert_status 2
	assert_contains "${output}" "owner/repo@skill"
}

@test "toolsmith vendor: a repo-root forge URL is refused — it points at no skill" {
	run bash "${VS}" "https://github.com/acme/toolbox" --root "$(project plain-agent)"
	assert_status 2
	assert_contains "${output}" "/tree/"
}

@test "toolsmith vendor: a local name that is not kebab-case is refused" {
	run bash "${VS}" "acme/toolbox@widget-maker" --name "Widget_Maker" --root "$(project plain-agent)"
	assert_status 2
	assert_contains "${output}" "kebab-case"
}

@test "toolsmith vendor: a name an enabled plugin stages is refused before anything is fetched" {
	local p
	p="$(project rulesync-layout)"
	seed_remote
	run bash "${VS}" "acme/toolbox@widget-maker" --name vendored-alpha --root "${p}"
	assert_status 2
	assert_contains "${output}" "staged by an enabled plugin"
	[ ! -d "${p}/tmp/vendor-skill" ]
}

@test "toolsmith vendor: a layout with no staged registry cannot refuse for that reason" {
	# The same name in a layout that stages nothing is free — "nothing is staged"
	# and "nothing can be staged" are different answers, and only one refuses.
	local p
	p="$(project plain-agent)"
	seed_remote
	run bash "${VS}" "acme/toolbox@widget-maker" --name vendored-alpha --root "${p}"
	assert_status 0
	[ -f "${p}/.claude/skills/vendored-alpha/SKILL.md" ]
}

@test "toolsmith vendor: a project with no agent-config layout is refused, not guessed at" {
	run bash "${VS}" "acme/toolbox@widget-maker" --root "${FIXROOT}/unmarked"
	assert_status 2
	assert_contains "${output}" "no agent-config layout"
}

# --------------------------------------------------------- the copy per layout --

@test "toolsmith vendor: the copy, the record and the sync line are all the layout's own" {
	local p
	p="$(project rulesync-layout)"
	seed_remote
	run bash "${VS}" "acme/toolbox@widget-maker" --root "${p}"
	assert_status 0

	[ -f "${p}/.rulesync/skills/widget-maker/SKILL.md" ]
	run grep -q "Upstream body." "${p}/.rulesync/skills/widget-maker/SKILL.md"
	assert_status 0
	[ -f "${p}/.rulesync/skills/widget-maker/LICENSE" ]

	local reg="${p}/.rulesync/vendored-skills.json"
	[ -f "${reg}" ]
	run jq -e '.skills["widget-maker"].source == "acme/toolbox"' "${reg}"
	assert_status 0
	run jq -e '.skills["widget-maker"].path == "skills/widget-maker"' "${reg}"
	assert_status 0
	run jq -e '.skills["widget-maker"].commit | length == 40' "${reg}"
	assert_status 0
	run jq -e '.skills["widget-maker"].license == "LICENSE"' "${reg}"
	assert_status 0
}

@test "toolsmith vendor: a generated layout gets the targets block; a plain one does not" {
	local rs pa
	rs="$(project rulesync-layout)"
	pa="$(project plain-agent)"
	seed_remote

	run bash "${VS}" "acme/toolbox@widget-maker" --root "${rs}"
	assert_status 0
	assert_contains "$(cat "${rs}/.rulesync/skills/widget-maker/SKILL.md")" "targets:"
	assert_contains "${output}" "fixture-sync --all"

	run bash "${VS}" "acme/toolbox@widget-maker" --root "${pa}"
	assert_status 0
	assert_not_contains "$(cat "${pa}/.claude/skills/widget-maker/SKILL.md")" "targets:"
	assert_contains "${output}" "This layout has no sync step"
	[ -f "${pa}/.claude/vendored-skills.json" ]
	[ ! -e "${pa}/.rulesync/vendored-skills.json" ]
}

@test "toolsmith vendor: the copy is linted on the way in" {
	local p
	p="$(project plain-agent)"
	seed_remote
	run bash "${VS}" "acme/toolbox@widget-maker" --root "${p}"
	assert_status 0
	assert_contains "${output}" "dev-tool lint clean"
}

# ------------------------------------------------------------- the refresh ---

@test "toolsmith vendor: vendoring the same name twice without --update is refused" {
	local p
	p="$(project plain-agent)"
	seed_remote
	run bash "${VS}" "acme/toolbox@widget-maker" --root "${p}"
	assert_status 0
	run bash "${VS}" "acme/toolbox@widget-maker" --root "${p}"
	assert_status 2
	assert_contains "${output}" "already exists"
}

@test "toolsmith vendor: --update re-fetches from the record and stays idempotent" {
	local p
	p="$(project rulesync-layout)"
	seed_remote
	run bash "${VS}" "acme/toolbox@widget-maker" --root "${p}"
	assert_status 0
	run bash "${VS}" --update widget-maker --root "${p}"
	assert_status 0
	# A second targets block would mean the injection ran over its own output.
	run grep -c '^targets:' "${p}/.rulesync/skills/widget-maker/SKILL.md"
	[ "${output}" = "1" ]
}

@test "toolsmith vendor: --update on a name nothing vendored is refused" {
	run bash "${VS}" --update never-vendored --root "$(project plain-agent)"
	assert_status 2
}

@test "toolsmith vendor: --list reports an empty record, then the row it wrote" {
	local p
	p="$(project plain-agent)"
	run bash "${VS}" --list --root "${p}"
	assert_status 0
	assert_contains "${output}" "no vendored skills yet"

	seed_remote
	run bash "${VS}" "acme/toolbox@widget-maker" --root "${p}"
	assert_status 0
	run bash "${VS}" --list --root "${p}"
	assert_status 0
	assert_contains "${output}" "widget-maker"
	assert_contains "${output}" "acme/toolbox@"
}
