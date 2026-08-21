#!/usr/bin/env bats
#
# tests/test-toolsmith-skills.bats
#
# The two skills toolsmith ships were MOVED out of a project that had exactly
# one agent-config layout, and their prose named that layout directly — the
# source directory, the sync command, the settings file. A wholesale move keeps
# the words; only a rewrite removes them.
#
# So the contract asserted here is a confinement: the origin project's layout
# literal may appear in EXACTLY ONE place in each body, the rulesync row of the
# three-row layout table, where it is one option among three. Anywhere else it
# is a leftover, and a reader of a plugin repo or a plain checkout is being sent
# to a directory their project does not have.
#
# A skill body has no CLI boundary, so this is a static grep. The origin's sync
# command is asserted by its NEUTRAL half (`make ai`): its other half names the
# company, which the repository's own neutrality hook rejects everywhere, so
# spelling it out here would be both redundant and itself a violation.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tests/helpers/common.bash"
	SKILLS="${REPO_ROOT}/plugins/toolsmith/skills"
	DISCOVERY="${SKILLS}/skill-discovery/SKILL.md"
	AUTHORING="${SKILLS}/dev-tool-authoring/SKILL.md"
	TEMPLATES="${SKILLS}/dev-tool-authoring/templates"
}

# The rulesync row of the layout table — the ONE line licensed to name the
# rulesync source directory, in either body.
ROW_PREFIX='| `rulesync` |'

# assert_confined_to_row <file> <literal> — every line carrying <literal> must
# be the layout table's rulesync row, and at least one line must carry it (a
# deleted table would otherwise pass by vacuum).
assert_confined_to_row() {
	local file="$1" literal="$2" hits offending
	hits="$(grep -c -F -- "${literal}" "${file}" || true)"
	if [ "${hits}" -eq 0 ]; then
		printf '%s: the layout table is gone — no line names %s at all\n' "${file}" "${literal}" >&2
		return 1
	fi
	offending="$(grep -n -F -- "${literal}" "${file}" | grep -v -F -- "${ROW_PREFIX}" || true)"
	if [ -n "${offending}" ]; then
		printf '%s: %s outside the rulesync row:\n%s\n' "${file}" "${literal}" "${offending}" >&2
		return 1
	fi
}

# assert_absent <file> <literal>
assert_absent() {
	local file="$1" literal="$2" offending
	offending="$(grep -n -F -- "${literal}" "${file}" || true)"
	if [ -n "${offending}" ]; then
		printf '%s: must not name %s:\n%s\n' "${file}" "${literal}" "${offending}" >&2
		return 1
	fi
}

# ------------------------------------------------------------ both skills --

@test "toolsmith skills: both moved skills are shipped inside the plugin" {
	[ -f "${DISCOVERY}" ]
	[ -f "${AUTHORING}" ]
}

@test "toolsmith skills: each body carries the three-row layout table" {
	local file
	for file in "${DISCOVERY}" "${AUTHORING}"; do
		assert_contains "$(cat "${file}")" '| `rulesync` |'
		assert_contains "$(cat "${file}")" '| `plugin` |'
		assert_contains "$(cat "${file}")" '| `plain` |'
	done
}

@test "toolsmith skills: the rulesync source directory appears only in the rulesync row" {
	assert_confined_to_row "${DISCOVERY}" '.rulesync'
	assert_confined_to_row "${AUTHORING}" '.rulesync'
}

@test "toolsmith skills: no body names the origin project's sync command" {
	assert_absent "${DISCOVERY}" 'make ai'
	assert_absent "${AUTHORING}" 'make ai'
}

@test "toolsmith skills: no body names the Claude settings file" {
	assert_absent "${DISCOVERY}" '.claude/settings.json'
	assert_absent "${AUTHORING}" '.claude/settings.json'
}

@test "toolsmith skills: a missing sync command is reported as none, not invented" {
	assert_contains "$(cat "${DISCOVERY}")" 'values.sync_cmd'
	assert_contains "$(cat "${AUTHORING}")" 'values.sync_cmd'
	assert_contains "$(cat "${DISCOVERY}")" 'never invent a command'
	assert_contains "$(cat "${AUTHORING}")" 'a fabricated sync command is worse'
}

@test "toolsmith skills: paths are read off the adapter rather than written out" {
	local file
	for file in "${DISCOVERY}" "${AUTHORING}"; do
		assert_contains "$(cat "${file}")" 'scripts/toolsmith.sh" --explain'
		assert_contains "$(cat "${file}")" 'values.skills_dir'
	done
}

@test "toolsmith skills: shipped scripts are addressed through the plugin root" {
	local file
	for file in "${DISCOVERY}" "${AUTHORING}"; do
		assert_contains "$(cat "${file}")" '${CLAUDE_PLUGIN_ROOT}/scripts/'
		assert_not_contains "$(cat "${file}")" 'bin/claude/'
		assert_not_contains "$(cat "${file}")" 'bin/ai/'
	done
}

@test "toolsmith skills: cross-references between the two carry the plugin prefix" {
	assert_contains "$(cat "${DISCOVERY}")" 'toolsmith:dev-tool-authoring'
	assert_contains "$(cat "${AUTHORING}")" 'toolsmith:skill-discovery'
}

@test "toolsmith skills: no editor-specific MCP tool call is hard-coded" {
	assert_not_contains "$(cat "${DISCOVERY}")" 'mcp__'
	assert_not_contains "$(cat "${AUTHORING}")" 'mcp__'
}

@test "toolsmith skills: a real ticket reference survives only as a placeholder" {
	# The origin body used a live ticket key to make the point; the rule it
	# states is the reason that key may not be the example.
	run grep -n -E '\b[A-Z]{2,5}-[0-9]{3,5}\b' "${AUTHORING}"
	[ "${status}" -ne 0 ] || assert_contains "${output}" 'ABC-1234'
}

# --------------------------------------------------------- the scaffolds ---

@test "toolsmith skills: the templates are split into one set per layout" {
	[ -d "${TEMPLATES}/rulesync" ]
	[ -d "${TEMPLATES}/plugin" ]
	[ -d "${TEMPLATES}/plain" ]
}

@test "toolsmith skills: each layout's scaffolds carry that layout's frontmatter shape" {
	# rulesync layers are generated from a config, so they declare targets.
	assert_contains "$(cat "${TEMPLATES}/rulesync/SKILL.md.tmpl")" 'targets:'
	assert_contains "$(cat "${TEMPLATES}/rulesync/command.md.tmpl")" 'claudecode:'
	# A plugin's files ARE the sources: no targets, no generator block.
	assert_not_contains "$(cat "${TEMPLATES}/plugin/SKILL.md.tmpl")" 'targets:'
	assert_not_contains "$(cat "${TEMPLATES}/plugin/command.md.tmpl")" 'claudecode:'
	assert_not_contains "$(cat "${TEMPLATES}/plain/SKILL.md.tmpl")" 'targets:'
}

@test "toolsmith skills: the plugin layout ships no rule scaffold, because it has no rules layer" {
	[ ! -e "${TEMPLATES}/plugin/rule.md.tmpl" ]
	[ -f "${TEMPLATES}/rulesync/rule.md.tmpl" ]
	[ -f "${TEMPLATES}/plain/rule.md.tmpl" ]
}

@test "toolsmith skills: the script scaffold is shared and carries no frontmatter" {
	[ -f "${TEMPLATES}/script.sh.tmpl" ]
	[ "$(head -1 "${TEMPLATES}/script.sh.tmpl")" = '#!/usr/bin/env bash' ]
}

@test "toolsmith skills: no scaffold hard-codes a developer's home directory" {
	run grep -rn -E '/(Users|home)/[a-z]' "${TEMPLATES}"
	[ "${status}" -ne 0 ]
}
