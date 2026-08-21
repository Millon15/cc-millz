#!/usr/bin/env bats
#
# tests/test-toolsmith-man.bats
#
# `/toolsmith:man` reads a project and explains it, so its whole risk surface is
# what it is allowed to touch and where it gets its facts:
#
#   1. READ-ONLY. Every mode explains; none installs, enables, vendors, or runs
#      a task-runner target. A help command that runs the thing it describes is
#      a different, much more dangerous command.
#   2. NOTHING HARD-CODED. In its origin project the target universe was one
#      fixed source directory, the how-do-I answer named that project's own task
#      runner, and the who-owns answer named its knowledge base. All three now
#      come from the adapter and the profile, and are asserted here to be read
#      from `values.*` rather than written into the body.
#
# The body is markdown with no executable seam, so the contract is a static
# grep — paired with a driven pass over the fixture profile, which supplies the
# knowledge skill and the runner ladder the Escalate branch consumes, and with
# the plugin's own linter over the shipped file.

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
	CMD="${PLUGIN}/commands/man.md"
	BODY="$(cat "${CMD}")"
	TS="${PLUGIN}/scripts/toolsmith.sh"
}

teardown() { teardown_tmp; }

# ------------------------------------------------------------- the package --

@test "toolsmith man: the command ships with intact frontmatter and stays user-invoked" {
	[ -f "${CMD}" ]
	[ "$(head -1 "${CMD}")" = "---" ]
	assert_contains "${BODY}" "description:"
	assert_contains "${BODY}" "argument-hint:"
	assert_contains "${BODY}" "disable-model-invocation: true"
}

@test "toolsmith man: the invocation it advertises is the namespaced one" {
	assert_contains "${BODY}" "/toolsmith:man <name>"
	assert_contains "${BODY}" "/toolsmith:man find <what you want>"
	# The origin shipped this as a bare `/man`, which now belongs to nobody.
	assert_not_contains "${BODY}" "name: /man"
}

@test "toolsmith man: the shipped body passes the plugin's own linter" {
	run bash "${PLUGIN}/scripts/validate-dev-tool.sh" "${CMD}"
	assert_status 0
	assert_contains "${output}" "lint clean"
}

@test "toolsmith man: the body names no path from the project it was extracted from" {
	assert_not_contains "${BODY}" "bin/claude/"
	assert_not_contains "${BODY}" "bin/ai/"
	assert_not_contains "${BODY}" ".rulesync/"
	assert_contains "${BODY}" '${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh'
}

# ------------------------------------------------------------ the dispatch --

@test "toolsmith man: the layout is resolved before the dispatch table" {
	local phase0 dispatch
	phase0="$(grep -n -F '## Phase 0 — Resolve the layout' "${CMD}" | head -1 | cut -d: -f1)"
	dispatch="$(grep -n -F '## Dispatch (MUST, in order)' "${CMD}" | head -1 | cut -d: -f1)"
	[ -n "${phase0}" ] && [ -n "${dispatch}" ]
	[ "${phase0}" -lt "${dispatch}" ]
	assert_contains "${BODY}" '${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain'
}

@test "toolsmith man: every dispatch mode has a row" {
	local mode
	for mode in Usage Lookup Suggest Escalate Find; do
		assert_contains "${BODY}" "**${mode}**"
	done
	assert_contains "${BODY}" '| starts with `find `'
}

@test "toolsmith man: the target universe is enumerated from the layout's own dirs" {
	local key
	for key in values.commands_dir values.skills_dir values.agents_dir values.rules_dir; do
		assert_contains "${BODY}" "${key}"
	done
	assert_contains "${BODY}" "NEVER pre-generate an index"
	assert_contains "${BODY}" "never a hard-coded path"
}

@test "toolsmith man: find mode searches beyond this machine, suggest mode stays local" {
	assert_contains "${BODY}" 'find-skill.sh" "<query>" --remote'
	assert_contains "${BODY}" 'find-skill.sh" "<text>" --no-remote'
}

@test "toolsmith man: find mode is read-only — it names the command, never runs it" {
	assert_contains "${BODY}" "NEVER installs, enables, unlocks or vendors"
	assert_contains "${BODY}" "NEVER run or spawn a target"
	assert_contains "${BODY}" "NEVER edit or write any file"
}

# ---------------------------------------------------- the profile-fed branch --

@test "toolsmith man: the escalation loads the profile's knowledge skill, never a named one" {
	assert_contains "${BODY}" "values.knowledge_skill"
	assert_contains "${BODY}" "the project declares no knowledge skill"
	assert_contains "${BODY}" "never invent an owner"
	assert_contains "${BODY}" "the ONLY skill this command may load"
}

@test "toolsmith man: the how-do-I answer walks the profile's runner ladder read-only" {
	assert_contains "${BODY}" "values.task_runner"
	assert_contains "${BODY}" "take the FIRST entry"
	assert_contains "${BODY}" "An empty ladder means the project declares no runner"
	assert_contains "${BODY}" "It NEVER runs one"
}

@test "toolsmith man: the fixture profile supplies both branches with real values" {
	run bash "${TS}" --explain --root "${FIXROOT}/rulesync-layout"
	assert_status 0
	assert_explain_source "${output}" knowledge_skill profile
	assert_explain_source "${output}" task_runner profile
	[ "$(printf '%s' "${output}" | jq -r '.values.knowledge_skill')" = "house-knowledge" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner[0]')" = "fixture-run" ]
}

@test "toolsmith man: a project declaring neither leaves both branches empty, not guessed" {
	run bash "${TS}" --explain --root "${FIXROOT}/plain-agent"
	assert_status 0
	assert_explain_source "${output}" knowledge_skill default
	[ "$(printf '%s' "${output}" | jq -r '.values.knowledge_skill')" = "null" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.task_runner | length')" = "0" ]
}

@test "toolsmith man: an unreadable profile stops the run instead of degrading silently" {
	assert_contains "${BODY}" "Exit 2 means no layout marker or an unreadable profile"
	run bash "${TS}" --explain --root "${FIXROOT}/bad-profile"
	assert_status 2
	assert_contains "${output}" "not readable JSON"
}

# --------------------------------------------------------------- the output --

@test "toolsmith man: the card format cites its source and keeps rules uninvokable" {
	assert_contains "${BODY}" "More information:"
	assert_contains "${BODY}" "- Applies when:"
	assert_contains "${BODY}" "4–8 scenarios"
}

@test "toolsmith man: the usage block covers every mode the dispatch table has" {
	local line
	for line in "/toolsmith:man <name>" "/toolsmith:man <what you want>" \
		"/toolsmith:man how do I <task>" "/toolsmith:man who owns <area>" \
		"/toolsmith:man find <what you want>"; do
		assert_contains "${BODY}" "${line}"
	done
}
