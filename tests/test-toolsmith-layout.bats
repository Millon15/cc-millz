#!/usr/bin/env bats
#
# tests/test-toolsmith-layout.bats
#
# toolsmith.sh has a real CLI boundary, so its contract is driven rather than
# grepped. Every case asserts the VALUE and the SOURCE through
# assert_explain_source: a path that happens to be right because the adapter
# guessed, or a layout that is right only because it fell through to the last
# branch, is exactly the bug this suite exists to catch.
#
# The fixtures are assembled once per file into BATS_FILE_TMPDIR. Two of them
# cannot be committed as they are — an empty directory has nothing to track —
# and the adapter walks UPWARDS, so building them inside the repo would let the
# repo's own CLAUDE.md answer for the unmarked case.

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
	TS="${PLUGIN}/scripts/toolsmith.sh"
	RULESYNC="${FIXROOT}/rulesync-layout"
	PLUGIN_LAYOUT="${FIXROOT}/plugin-layout"
	PLAIN="${FIXROOT}/plain-agent"
}

teardown() { teardown_tmp; }

# ------------------------------------------------------------- the package --

@test "toolsmith: the plugin manifest is 0.1.0 with an empty dependencies field" {
	run jq -r '.name, .version' "${PLUGIN}/.claude-plugin/plugin.json"
	assert_status 0
	assert_contains "${output}" "toolsmith"
	assert_contains "${output}" "0.1.0"
	[ "$(jq -r '.dependencies | length' "${PLUGIN}/.claude-plugin/plugin.json")" = "0" ]
}

@test "toolsmith: every shipped script is executable" {
	[ -x "${TS}" ]
	[ -x "${PLUGIN}/scripts/find-skill.sh" ]
	[ -x "${PLUGIN}/scripts/validate-dev-tool.sh" ]
	[ -x "${PLUGIN}/scripts/vendor-skill.sh" ]
}

@test "toolsmith: an invocation without --explain is a usage error, not a default run" {
	run bash "${TS}" --root "${PLAIN}"
	assert_status 2
	assert_contains "${output}" "--explain"
}

# ------------------------------------------------------- the rulesync layout --

@test "toolsmith: a rulesync config file selects the rulesync layout and its dirs" {
	run bash "${TS}" --explain --root "${RULESYNC}"
	assert_status 0
	assert_explain_source "${output}" layout detected:rulesync-config
	assert_explain_source "${output}" root detected:rulesync-config
	assert_explain_source "${output}" skills_dir detected:rulesync-config
	assert_explain_source "${output}" commands_dir detected:rulesync-config
	assert_explain_source "${output}" agents_dir detected:rulesync-config
	assert_explain_source "${output}" rules_dir detected:rulesync-config
	[ "$(printf '%s' "${output}" | jq -r '.values.layout')" = "rulesync" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.skills_dir')" = ".rulesync/skills" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.commands_dir')" = ".rulesync/commands" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.agents_dir')" = ".rulesync/subagents" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.rules_dir')" = ".rulesync/rules" ]
}

@test "toolsmith: the rulesync layout is NOT reached by falling through the plain markers" {
	# The fixture carries a generated .claude/ directory, which is a plain-layout
	# marker. Marker order is what keeps it from answering first.
	[ -d "${RULESYNC}/.claude" ]
	run bash "${TS}" --explain --root "${RULESYNC}"
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.layout')" = "rulesync" ]
}

@test "toolsmith: only a generated layout reports generated dirs and a staged registry" {
	run bash "${TS}" --explain --root "${RULESYNC}"
	assert_status 0
	assert_explain_source "${output}" generated_dirs detected:rulesync-config
	assert_explain_source "${output}" staged_registry detected:rulesync-config
	[ "$(printf '%s' "${output}" | jq -r '.values.generated_dirs | length')" -ge 5 ]
	[ "$(printf '%s' "${output}" | jq -r '.values.staged_registry')" = ".rulesync/.staged-plugins.json" ]

	run bash "${TS}" --explain --root "${PLAIN}"
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.generated_dirs | length')" = "0" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.staged_registry')" = "null" ]
}

@test "toolsmith: a registry the layout defines but the project has not written reports absent" {
	cp -R "${RULESYNC}" "${TMP}/no-registry"
	rm -f "${TMP}/no-registry/.rulesync/.staged-plugins.json"
	run bash "${TS}" --explain --root "${TMP}/no-registry"
	assert_status 0
	assert_explain_source "${output}" staged_registry detected:rulesync-config
	[ "$(printf '%s' "${output}" | jq -r '.values.staged_registry')" = "null" ]
}

# --------------------------------------------------------- the plugin layout --

@test "toolsmith: a plugin manifest selects the plugin layout, whose sources ARE the shipped dirs" {
	run bash "${TS}" --explain --root "${PLUGIN_LAYOUT}"
	assert_status 0
	assert_explain_source "${output}" layout detected:plugin-manifest
	assert_explain_source "${output}" skills_dir detected:plugin-manifest
	[ "$(printf '%s' "${output}" | jq -r '.values.layout')" = "plugin" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.skills_dir')" = "skills" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.commands_dir')" = "commands" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.agents_dir')" = "agents" ]
}

@test "toolsmith: a layer the layout does not have reports null, not a path nothing would find" {
	run bash "${TS}" --explain --root "${PLUGIN_LAYOUT}"
	assert_status 0
	assert_explain_source "${output}" rules_dir detected:plugin-manifest
	[ "$(printf '%s' "${output}" | jq -r '.values.rules_dir')" = "null" ]
	# The field order survives the empty layer: a tab is IFS whitespace, so a
	# collapsed empty field would shift every path after it by one.
	[ "$(printf '%s' "${output}" | jq -r '.values.vendor_registry')" = "vendored-skills.json" ]
}

# ---------------------------------------------------------- the plain layout --

@test "toolsmith: an agent-config marker selects the plain layout" {
	run bash "${TS}" --explain --root "${PLAIN}"
	assert_status 0
	assert_explain_source "${output}" layout detected:agent-marker
	assert_explain_source "${output}" skills_dir detected:agent-marker
	[ "$(printf '%s' "${output}" | jq -r '.values.layout')" = "plain" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.skills_dir')" = ".claude/skills" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.vendor_registry')" = ".claude/vendored-skills.json" ]
}

@test "toolsmith: each of the plain markers works on its own" {
	local marker
	for marker in AGENTS.md CLAUDE.md .claude .cursor .agents; do
		mkdir -p "${TMP}/marker/${marker}-case"
		case "${marker}" in
		.*) mkdir -p "${TMP}/marker/${marker}-case/${marker}" ;;
		*) printf 'x\n' >"${TMP}/marker/${marker}-case/${marker}" ;;
		esac
		run bash "${TS}" --explain --root "${TMP}/marker/${marker}-case"
		assert_status 0
		[ "$(printf '%s' "${output}" | jq -r '.values.layout')" = "plain" ]
	done
}

# ------------------------------------------------------------ the error path --

@test "toolsmith: an unmarked directory exits 2 and names every marker it looked for" {
	run bash "${TS}" --explain --root "${FIXROOT}/unmarked"
	assert_status 2
	assert_contains "${output}" "rulesync.jsonc"
	assert_contains "${output}" ".claude-plugin/plugin.json"
	assert_contains "${output}" "AGENTS.md"
	assert_contains "${output}" "no agent-config layout"
}

@test "toolsmith: an unreadable profile exits 2 rather than falling back to detection" {
	run bash "${TS}" --explain --root "${FIXROOT}/bad-profile"
	assert_status 2
	assert_contains "${output}" "not readable JSON"
}

# ---------------------------------------------------------- the profile keys --

@test "toolsmith: the four profile keys come from the profile, and are reported as such" {
	run bash "${TS}" --explain --root "${RULESYNC}"
	assert_status 0
	assert_explain_source "${output}" sync_cmd profile
	assert_explain_source "${output}" docs_cmd profile
	assert_explain_source "${output}" knowledge_skill profile
	assert_explain_source "${output}" task_runner profile
	[ "$(printf '%s' "${output}" | jq -r '.values.sync_cmd')" = "fixture-sync --all" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.docs_cmd')" = "fixture-docs build" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.knowledge_skill')" = "house-knowledge" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner | join(",")')" = "fixture-run,make" ]
	assert_contains "$(printf '%s' "${output}" | jq -r '.profile_file')" ".toolsmith.json"
}

@test "toolsmith: a layout or path key placed in the profile is IGNORED, not honoured" {
	# The fixture profile sets both to values no detector could produce.
	grep -q 'IGNORED-layout-key' "${RULESYNC}/.toolsmith.json"
	grep -q 'IGNORED-path-key' "${RULESYNC}/.toolsmith.json"
	run bash "${TS}" --explain --root "${RULESYNC}"
	assert_status 0
	assert_not_contains "${output}" "IGNORED-layout-key"
	assert_not_contains "${output}" "IGNORED-path-key"
}

@test "toolsmith: with no profile the three unguessable keys report default, never a guess" {
	run bash "${TS}" --explain --root "${PLAIN}"
	assert_status 0
	assert_explain_source "${output}" sync_cmd default
	assert_explain_source "${output}" docs_cmd default
	assert_explain_source "${output}" knowledge_skill default
	[ "$(printf '%s' "${output}" | jq -r '.values.sync_cmd')" = "null" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.docs_cmd')" = "null" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.knowledge_skill')" = "null" ]
	[ "$(printf '%s' "${output}" | jq -r '.profile_file')" = "null" ]
}

@test "toolsmith: the task-runner ladder falls to the build files, then to empty" {
	run bash "${TS}" --explain --root "${PLUGIN_LAYOUT}"
	assert_status 0
	assert_explain_source "${output}" task_runner detected:build-files
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner | join(",")')" = "make" ]

	# A justfile outranks a Makefile, and both may appear in one ladder.
	cp -R "${PLUGIN_LAYOUT}" "${TMP}/two-runners"
	printf 'default:\n\t@echo x\n' >"${TMP}/two-runners/justfile"
	run bash "${TS}" --explain --root "${TMP}/two-runners"
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner | join(",")')" = "just,make" ]

	run bash "${TS}" --explain --root "${PLAIN}"
	assert_status 0
	assert_explain_source "${output}" task_runner default
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner | length')" = "0" ]
}

@test "toolsmith: a ladder entry holding a space survives as ONE entry" {
	cp -R "${PLAIN}" "${TMP}/node-runner"
	printf '{"scripts":{"test":"echo"}}\n' >"${TMP}/node-runner/package.json"
	run bash "${TS}" --explain --root "${TMP}/node-runner"
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner | length')" = "1" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner[0]')" = "npm run" ]
}

# ------------------------------------------------------------------ the walk --

@test "toolsmith: the layout is found by walking up from a subdirectory" {
	run bash "${TS}" --explain --root "${RULESYNC}/.rulesync/skills"
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.layout')" = "rulesync" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.root')" = "$(cd "${RULESYNC}" && pwd -P)" ]
}

# ------------------------------------------------------------- the contract --

@test "toolsmith: every values key is mirrored in sources, in all three layouts" {
	local dir
	for dir in "${RULESYNC}" "${PLUGIN_LAYOUT}" "${PLAIN}"; do
		run bash "${TS}" --explain --root "${dir}"
		assert_status 0
		assert_explain_complete "${output}"
		[ "$(printf '%s' "${output}" | jq -r '.plugin')" = "toolsmith" ]
	done
}

@test "toolsmith: --explain has no side effects on the project it reads" {
	local before after
	before="$(find "${PLAIN}" | sort)"
	run bash "${TS}" --explain --root "${PLAIN}"
	assert_status 0
	after="$(find "${PLAIN}" | sort)"
	[ "${before}" = "${after}" ]
}
