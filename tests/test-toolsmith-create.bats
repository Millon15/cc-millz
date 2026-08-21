#!/usr/bin/env bats
#
# tests/test-toolsmith-create.bats
#
# `/toolsmith:create` is a markdown command: there is no executable seam that
# could run it to its authoring phase, so its contract is asserted two ways.
#
#   1. STATICALLY, over the shipped body — the phase order, the reuse gate, the
#      four-way decision, the collision check, and the two SOFT dependencies.
#      A soft dependency is only soft if the else-branch is IN the body: a row
#      that loads a companion skill when the session has one is worth nothing
#      unless the body also carries what to do when it does not, which for this
#      command is the eight-line authoring checklist and the five inline design
#      questions. Both halves are asserted here, item by item.
#   2. DRIVEN, over the fixtures — the command reads `values.layout` and copies
#      the template set named by it, so for each layout fixture the adapter's
#      answer and the template directory that answer selects must agree. A body
#      naming a directory the plugin does not ship is a broken scaffold path,
#      and nothing static would catch it.
#
# The origin of this command shipped in a single-layout project and named that
# project's script directory and permissions file directly. Those literals are
# asserted ABSENT: a reader of a plugin install has neither.

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
	CMD="${PLUGIN}/commands/create.md"
	BODY="$(cat "${CMD}")"
	TS="${PLUGIN}/scripts/toolsmith.sh"
	TEMPLATES="${PLUGIN}/skills/dev-tool-authoring/templates"
}

teardown() { teardown_tmp; }

# line_of <heading> — the line number of a heading, for order assertions.
line_of() {
	grep -n -F -- "$1" "${CMD}" | head -1 | cut -d: -f1
}

# ------------------------------------------------------------- the package --

@test "toolsmith create: the command ships with intact frontmatter and stays user-invoked" {
	[ -f "${CMD}" ]
	[ "$(head -1 "${CMD}")" = "---" ]
	assert_contains "${BODY}" "description:"
	assert_contains "${BODY}" "argument-hint:"
	assert_contains "${BODY}" "disable-model-invocation: true"
}

@test "toolsmith create: the body names no path from the project it was extracted from" {
	assert_not_contains "${BODY}" "bin/claude/"
	assert_not_contains "${BODY}" "bin/ai/"
	assert_not_contains "${BODY}" "permissions.json"
	assert_not_contains "${BODY}" ".rulesync/"
}

@test "toolsmith create: every script it runs is addressed through the plugin root" {
	assert_contains "${BODY}" '${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain'
	assert_contains "${BODY}" '${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh'
	assert_contains "${BODY}" '${CLAUDE_PLUGIN_ROOT}/scripts/validate-dev-tool.sh'
}

@test "toolsmith create: the shipped body passes the plugin's own linter" {
	run bash "${PLUGIN}/scripts/validate-dev-tool.sh" "${CMD}"
	assert_status 0
	assert_contains "${output}" "lint clean"
}

# ------------------------------------------------------------ phase order ---

@test "toolsmith create: the layout is resolved before anything else runs" {
	local phase0 gate phase1
	phase0="$(line_of '## Phase 0 — Resolve the layout')"
	gate="$(line_of '## Phase 0.5 — Reuse before build')"
	phase1="$(line_of '## Phase 1 — Intent')"
	[ -n "${phase0}" ] && [ -n "${gate}" ] && [ -n "${phase1}" ]
	[ "${phase0}" -lt "${gate}" ]
	[ "${gate}" -lt "${phase1}" ]
	assert_contains "${BODY}" "(ALWAYS FIRST)"
}

@test "toolsmith create: exit 2 from the adapter stops the run instead of guessing" {
	assert_contains "${BODY}" "Exit 2 means no layout marker"
	assert_contains "${BODY}" "NEVER guess a directory"
}

@test "toolsmith create: every layer path is read off the adapter, none written out" {
	local key
	for key in values.layout values.root values.skills_dir values.commands_dir \
		values.agents_dir values.rules_dir values.generated_dirs values.sync_cmd; do
		assert_contains "${BODY}" "${key}"
	done
	assert_contains "${BODY}" "does not exist in this layout"
}

# ------------------------------------------------------------- the gate -----

@test "toolsmith create: the reuse search is a hard gate that loads the discovery skill" {
	assert_contains "${BODY}" "Reuse before build (HARD GATE)"
	assert_contains "${BODY}" "toolsmith:skill-discovery"
	assert_contains "${BODY}" "MUST complete Phase 0.5 before Phase 1"
}

@test "toolsmith create: the remote tier is on by default with a documented opt-out" {
	assert_contains "${BODY}" 'find-skill.sh" "<query>" --remote'
	assert_contains "${BODY}" "--no-remote"
}

@test "toolsmith create: the four-way decision names every branch" {
	local decision
	for decision in adopt extend create stop; do
		assert_contains "${BODY}" "**${decision}**"
	done
}

@test "toolsmith create: the collision check calls the finder rather than a hand-kept list" {
	assert_contains "${BODY}" 'find-skill.sh" --exact <tool-name> --remote'
	assert_contains "${BODY}" "NAME FREE"
	assert_contains "${BODY}" "NAME TAKEN"
}

# ------------------------------------------------- the two SOFT dependencies --

@test "toolsmith create: the design dialogue degrades to five inline questions" {
	assert_contains "${BODY}" "Design dialogue (HARD GATE, SOFT dependency)"
	assert_contains "${BODY}" "grilling skill is in the session's skill list"
	assert_contains "${BODY}" "No such skill is available"
	assert_contains "${BODY}" "all five in ONE question round"
	# The questions themselves, not a promise of them.
	local q
	for q in "What inputs does it accept" "What outputs does it produce" \
		"What existing tools" "What are its failure modes" "How will it be validated"; do
		assert_contains "${BODY}" "${q}"
	done
}

@test "toolsmith create: the authoring standard degrades to the eight-line checklist" {
	assert_contains "${BODY}" "Author the layers (SOFT dependency)"
	assert_contains "${BODY}" "companion authoring skill is in the session's skill list"
	assert_contains "${BODY}" "eight-line checklist below"
	local item
	for item in "Invocation model" "Description as triggers only" "Information hierarchy" \
		"Pruning" "Leading words" "Completion criteria" "No negation alone" \
		"Single source of truth"; do
		assert_contains "${BODY}" "**${item}**"
	done
}

@test "toolsmith create: the checklist is eight items, and the eighth is numbered 8" {
	# A ninth item added without renumbering, or a truncated list, both read as
	# "the checklist" to a static contains-check. The count is the assertion.
	local items
	items="$(sed -n '/^The eight-line authoring checklist:$/,/^\*\*Lint after EACH layer/p' "${CMD}" |
		grep -c '^[0-9]\+\. \*\*' || true)"
	[ "${items}" = "8" ] || {
		printf 'the authoring checklist has %s items, expected 8\n' "${items}" >&2
		return 1
	}
	assert_contains "${BODY}" "8. **Single source of truth**"
}

@test "toolsmith create: neither companion is a dependency — absence never blocks a phase" {
	assert_contains "${BODY}" "Neither path is optional and neither is preferred"
	assert_contains "${BODY}" "Absence of the companion is never a licence to author unguided"
	# A hard requirement would name the plugin outside its conditional row.
	run grep -c -F 'mattpocock-skills:' "${CMD}"
	[ "${output}" = "2" ]
}

@test "toolsmith create: the compression step runs only when the tool for it is present" {
	assert_contains "${BODY}" "Compression (conditional)"
	assert_contains "${BODY}" "compression skill is in the session's skill list"
	assert_contains "${BODY}" "skip silently"
}

@test "toolsmith create: a project with no sync step is told so rather than given one" {
	assert_contains "${BODY}" "NEVER invent a sync command"
	assert_contains "${BODY}" "sync: none"
}

# ------------------------------------------------- driven: layout → templates --

@test "toolsmith create: each fixture layout selects a template set the plugin ships" {
	local fixture layout
	for fixture in rulesync-layout plugin-layout plain-agent; do
		run bash "${TS}" --explain --root "${FIXROOT}/${fixture}"
		assert_status 0
		layout="$(printf '%s' "${output}" | jq -r '.values.layout')"
		[ -d "${TEMPLATES}/${layout}" ] || {
			printf '%s resolves layout %s, but no template set ships for it\n' \
				"${fixture}" "${layout}" >&2
			return 1
		}
		[ -f "${TEMPLATES}/${layout}/SKILL.md.tmpl" ]
		[ -f "${TEMPLATES}/${layout}/command.md.tmpl" ]
		[ -f "${TEMPLATES}/${layout}/agent.md.tmpl" ]
	done
}

@test "toolsmith create: the scaffold path in the body is the one that resolves on disk" {
	# The body writes the path with the JSON key in it; substituting a fixture's
	# answer for that key has to produce a file, or the scaffold step is broken.
	assert_contains "${BODY}" 'skills/dev-tool-authoring/templates/{values.layout}/<layer>.md.tmpl'
	run bash "${TS}" --explain --root "${FIXROOT}/plain-agent"
	assert_status 0
	local layout
	layout="$(printf '%s' "${output}" | jq -r '.values.layout')"
	[ -f "${TEMPLATES}/${layout}/rule.md.tmpl" ]
	assert_contains "${BODY}" 'templates/script.sh.tmpl'
	[ -f "${TEMPLATES}/script.sh.tmpl" ]
}

@test "toolsmith create: a layer the fixture layout lacks has no scaffold to fill" {
	# The plugin layout reports rules_dir null, and ships no rule scaffold. The
	# body's rule about dropping a null layer is what keeps those two in step.
	run bash "${TS}" --explain --root "${FIXROOT}/plugin-layout"
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.rules_dir')" = "null" ]
	[ ! -e "${TEMPLATES}/plugin/rule.md.tmpl" ]
	assert_contains "${BODY}" "never invent a directory for it"
}

@test "toolsmith create: the collision check finds a name the fixture already declares" {
	command -v bun >/dev/null 2>&1 || skip "bun is not installed"
	# The body promises `--exact <tool-name>` reports a clash. Driven against the
	# decoy, so the promise has a run behind it rather than a grep.
	run bash "${PLUGIN}/scripts/find-skill.sh" --exact create --root "${FIXROOT}/decoy-repo" --tier project
	assert_status 0
	assert_contains "${output}" "NAME TAKEN"
}

# ------------------------------------------------------- the registration ---

@test "toolsmith create: the plugin is registered in the marketplace catalogue" {
	run jq -r '.plugins[] | select(.name == "toolsmith") | .source' "${REPO_ROOT}/.claude-plugin/marketplace.json"
	assert_status 0
	assert_contains "${output}" "./plugins/toolsmith"
}

@test "toolsmith create: the provenance sentence is carried by every catalogue surface" {
	local sentence="Extracted from a private monorepo."
	assert_contains "$(jq -r '.plugins[] | select(.name == "toolsmith") | .description' "${REPO_ROOT}/.claude-plugin/marketplace.json")" "${sentence}"
	assert_contains "$(grep -F 'plugins/toolsmith/README.md' "${REPO_ROOT}/README.md")" "${sentence}"
	assert_contains "$(cat "${PLUGIN}/README.md")" "${sentence}"
	assert_contains "$(sed -n '/^## toolsmith v/,/^## [a-z]/p' "${REPO_ROOT}/CHANGELOG.md")" "${sentence}"
}

# ------------------------------------------------------ the four basenames ---

@test "toolsmith create: create, man, check and retire are unique across every plugin" {
	local name matches
	for name in create man check retire; do
		matches="$(cd "${REPO_ROOT}" && find plugins -path "*/commands/${name}.md" | sort)"
		[ "$(printf '%s\n' "${matches}" | wc -l | tr -d ' ')" = "1" ] || {
			printf 'command basename %s is claimed more than once:\n%s\n' "${name}" "${matches}" >&2
			return 1
		}
		assert_contains "${matches}" "plugins/toolsmith/commands/${name}.md"
	done
}
