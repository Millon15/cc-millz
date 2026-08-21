#!/usr/bin/env bats
#
# tests/test-toolsmith-find-skill.bats
#
# The finder is what makes "search before you build" cheap enough to be a gate,
# so the two ways it can quietly stop working are what this suite drives:
#
#   1. It reads the WRONG directories. In its origin project the tier walked one
#      hard-coded source directory; here it asks the layout adapter, so each
#      fixture layout must surface its own layers and no other layout's.
#   2. It goes to the NETWORK when nobody asked. The default run is offline —
#      the remote tier is opt-in — and a default that quietly reaches out turns
#      every authoring flow into a run that fails without a connection.
#
# The ranking is asserted against `fixtures/toolsmith/ranking/expected-ranking.txt`,
# a truth table of query → ordered names. `--tier project` keeps the answer to
# the fixture: the developer's own user, installed and marketplace tiers cannot
# reorder it, and a name absent from the expected list must score zero.
#
# The `--exact` collision mode has its own suite, tests/test-toolsmith-exact.bats.

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
	PLUGIN="${REPO_ROOT}/plugins/toolsmith"
	FS="${PLUGIN}/scripts/find-skill.sh"
	ENGINE="${PLUGIN}/scripts/find-skill.ts"
	RANKING_FIXTURE="${BATS_TEST_DIRNAME}/fixtures/toolsmith/ranking/expected-ranking.txt"
	RULESYNC="${FIXROOT}/rulesync-layout"
	PLUGIN_LAYOUT="${FIXROOT}/plugin-layout"
	PLAIN="${FIXROOT}/plain-agent"
	RANKING="${FIXROOT}/ranking-layout"
}

teardown() { teardown_tmp; }

need_bun() { command -v bun >/dev/null 2>&1 || skip "bun is not installed"; }

# ---------------------------------------------------------------- wrapper ---

@test "toolsmith find: the wrapper and its engine both ship, and the wrapper is executable" {
	[ -f "${ENGINE}" ]
	[ -x "${FS}" ]
	run bash -n "${FS}"
	assert_status 0
}

@test "toolsmith find: no arguments prints usage and exits 0" {
	run bash "${FS}"
	assert_status 0
	assert_contains "${output}" "usage: find-skill.sh"
	assert_contains "${output}" "--exact"
	assert_contains "${output}" "--root"
}

@test "toolsmith find: the wrapper hard-codes no home directory and no origin-project path" {
	local body
	body="$(cat "${FS}")"
	assert_not_contains "${body}" "/Users/"
	assert_not_contains "${body}" "bin/claude/"
	assert_not_contains "${body}" "bin/ai/"
	assert_contains "${body}" 'CLAUDE_PLUGIN_ROOT'
}

# ------------------------------------------------------------ project tier --

@test "toolsmith find: a fixture project surfaces its own skill" {
	need_bun
	run bash "${FS}" "extract pdf text" --root "${RULESYNC}" --tier project
	assert_status 0
	assert_contains "${output}" "pdf-extractor"
}

@test "toolsmith find: every layer of the layout is walked, not only the skills" {
	need_bun
	run bash "${FS}" fixture --root "${RULESYNC}" --tier project --json
	assert_status 0
	local kinds
	kinds="$(printf '%s' "${output}" | jq -r '.hits[].kind' | sort -u | tr '\n' ',')"
	assert_contains "${kinds}" "command"
	assert_contains "${kinds}" "agent"
	assert_contains "${kinds}" "rule"
}

@test "toolsmith find: a copy an enabled plugin staged into the sources is flagged staged" {
	need_bun
	run bash "${FS}" "staged sources enabled plugin" --root "${RULESYNC}" --tier project
	assert_status 0
	assert_contains "${output}" "vendored-alpha"
	assert_contains "${output}" "staged"
}

@test "toolsmith find: each layout reads its OWN directories, never another layout's" {
	need_bun
	# The plugin fixture's skill sits under skills/, the plain fixture's under
	# .claude/skills/. Each is found from its own root and missed from the other.
	run bash "${FS}" "pack a release bundle" --root "${PLUGIN_LAYOUT}" --tier project
	assert_status 0
	assert_contains "${output}" "packer"

	run bash "${FS}" "pack a release bundle" --root "${PLAIN}" --tier project
	assert_status 0
	assert_not_contains "${output}" "packer"

	run bash "${FS}" notekeeper --root "${PLAIN}" --tier project
	assert_status 0
	assert_contains "${output}" "notekeeper"
}

@test "toolsmith find: --json carries the query and parseable hits" {
	need_bun
	run bash "${FS}" "extract pdf text" --root "${RULESYNC}" --tier project --json
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.query')" = "extract pdf text" ]
	[ "$(printf '%s' "${output}" | jq -r '.hits | length')" -ge 1 ]
	[ "$(printf '%s' "${output}" | jq -r '.hits[0].tier')" = "project" ]
}

# ------------------------------------------------------------- the ranking --

@test "toolsmith find: the ranking matches the fixture truth table, order included" {
	need_bun
	[ -f "${RANKING_FIXTURE}" ]
	local query expected actual rows=0
	while IFS=$'\t' read -r query expected; do
		case "${query}" in '' | '#'*) continue ;; esac
		rows=$((rows + 1))
		run bash "${FS}" "${query}" --root "${RANKING}" --tier project --json
		assert_status 0
		actual="$(printf '%s' "${output}" | jq -r '[.hits[].name] | join(",")')"
		[ "${actual}" = "${expected}" ] || {
			printf 'query "%s": expected %s, got %s\n' "${query}" "${expected}" "${actual}" >&2
			return 1
		}
	done <"${RANKING_FIXTURE}"
	[ "${rows}" -ge 3 ]
}

@test "toolsmith find: a name nothing in the query touches scores zero and is dropped" {
	need_bun
	# widget-painter sits in the same fixture and appears in no expected row.
	run bash "${FS}" "extract pdf text" --root "${RANKING}" --tier project --json
	assert_status 0
	assert_not_contains "${output}" "widget-painter"
}

# ------------------------------------------------------------- the network --

@test "toolsmith find: the default run is offline and says the remote tier is off" {
	need_bun
	SKILLS_API_URL="http://127.0.0.1:9" run bash "${FS}" "extract pdf text" --root "${RULESYNC}" --tier project
	assert_status 0
	assert_contains "${output}" "remote tier OFF"
}

@test "toolsmith find: --no-remote wins over --remote" {
	need_bun
	run bash "${FS}" "extract pdf text" --root "${RULESYNC}" --tier project --remote --no-remote
	assert_status 0
	assert_contains "${output}" "remote tier OFF"
}

# ----------------------------------------------------------- the error path --

@test "toolsmith find: an unknown flag prints usage and exits 2 instead of searching" {
	need_bun
	run bash "${FS}" query --bogus-flag
	assert_status 2
	assert_contains "${output}" "usage:"
}

@test "toolsmith find: an unmarked directory drops the project tier with a note" {
	need_bun
	run bash "${FS}" anything --root "${FIXROOT}/unmarked" --tier project
	assert_status 0
	assert_contains "${output}" "project tier skipped"
}
