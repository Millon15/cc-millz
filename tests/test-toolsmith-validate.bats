#!/usr/bin/env bats
#
# tests/test-toolsmith-validate.bats
#
# The linter never blocks: it always exits 0 and puts its verdict in the JSON
# `additionalContext` field, so every assertion here is on that text plus the
# exit code — never on an internal filter.
#
# What the port had to change: in its origin project the layer a file belonged
# to was decided by matching one hard-coded source directory, and every
# `.claude/**` path was by definition a GENERATED copy. Here the layout decides,
# and the SAME path means opposite things in two layouts — `.claude/skills/x` is
# a generated mirror under the rulesync fixture and the authoring source under
# the plain one. That inversion is the sharpest test in the file: a linter that
# kept the old literal passes everything else and fails it.
#
# Fixtures are per-test copies of the committed layout fixtures, so a test that
# writes into a project cannot leak into the next one.

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
	V="${PLUGIN}/scripts/validate-dev-tool.sh"
	TEMPLATES="${PLUGIN}/skills/dev-tool-authoring/templates"
}

teardown() { teardown_tmp; }

# project <fixture> — a private copy of a layout fixture; prints its path.
project() {
	local dest="${TMP}/proj-$1"
	[ -d "${dest}" ] || cp -R "${FIXROOT}/$1" "${dest}"
	printf '%s\n' "${dest}"
}

# write <path> <<'MD' … MD — a file plus the directories above it.
write() {
	mkdir -p "$(dirname "$1")"
	cat >"$1"
}

clean_skill() {
	write "$1" <<'MD'
---
name: foo
description: Use when foo.
---

# Foo

Body.
MD
}

# ---------------------------------------------------- (a) frontmatter line 1 --

@test "toolsmith validate: a body prepended before the frontmatter is flagged" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/skills/foo/SKILL.md" <<'MD'
★ preamble a hook printed ─────────
Clean!
---
name: foo
description: Use when foo.
---

# Foo
MD
	run bash "${V}" "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "FRONTMATTER BROKEN"
}

@test "toolsmith validate: an intact frontmatter draws no warning at all" {
	local p
	p="$(project rulesync-layout)"
	clean_skill "${p}/.rulesync/skills/foo/SKILL.md"
	run bash "${V}" "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "lint clean"
	assert_not_contains "${output}" "FRONTMATTER BROKEN"
}

# ------------------------------------------------- (b) dangling skill refs ----

@test "toolsmith validate: a reference to a skill nothing registers is flagged" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/skills/foo/SKILL.md" <<'MD'
---
name: foo
description: Use when foo.
---

MUST invoke the nonexistent-thing skill before proceeding.
MD
	run bash "${V}" "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "DANGLING SKILL REF"
	assert_contains "${output}" "nonexistent-thing"
}

@test "toolsmith validate: a skill the layout DOES have, and a namespaced one, both resolve" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/skills/foo/SKILL.md" <<'MD'
---
name: foo
description: Use when foo.
---

Load the `pdf-extractor` skill, then the `toolsmith:skill-discovery` skill.
MD
	run bash "${V}" "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_not_contains "${output}" "DANGLING SKILL REF"
}

# ------------------------------------------------------- (c) per-layer caps ---

@test "toolsmith validate: a rule past the line cap warns and still exits 0" {
	local p i
	p="$(project rulesync-layout)"
	{
		printf -- '---\ndescription: A big rule.\n---\n\n# Big Rule\n\n'
		for i in $(seq 1 60); do printf -- '- constraint %s\n' "${i}"; done
	} >"${p}/.rulesync/rules/big.md"
	run bash "${V}" "${p}/.rulesync/rules/big.md"
	assert_status 0
	assert_contains "${output}" "LINE CAP"
}

# ------------------------------------ (d) command substitution + home paths ---

@test "toolsmith validate: a real substitution and a concrete home path are both flagged" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/rules/cmd.md" <<'MD'
---
description: A rule with two offenders.
---

# Cmd Rule

Run `mkdir -p out/$(date +%Y)` then read /Users/someone/config.json.
MD
	run bash "${V}" "${p}/.rulesync/rules/cmd.md"
	assert_status 0
	assert_contains "${output}" "COMMAND SUBSTITUTION"
	assert_contains "${output}" "ABSOLUTE PATH"
}

@test "toolsmith validate: a layer that BANS substitution is not flagged for quoting the ban" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/rules/ban.md" <<'MD'
---
description: A rule forbidding substitution.
---

# Ban Rule

- NEVER `$(...)` substitution — use the two-call pattern instead.
- Two-step it: run the inner command, then use the literal value.
MD
	run bash "${V}" "${p}/.rulesync/rules/ban.md"
	assert_status 0
	assert_not_contains "${output}" "COMMAND SUBSTITUTION"
}

@test "toolsmith validate: the exemption is per-line — a real offender beside the ban still warns" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/rules/mixed.md" <<'MD'
---
description: A rule that preaches and offends.
---

# Mixed Rule

- NEVER `$(...)` substitution — two-call pattern instead.
- Build it: `mkdir -p out/$(date +%Y)`
MD
	run bash "${V}" "${p}/.rulesync/rules/mixed.md"
	assert_status 0
	assert_contains "${output}" "COMMAND SUBSTITUTION"
}

# --------------------------------------------------------- (e) docs footer ----

@test "toolsmith validate: a documentation footer in an agent-context file is flagged" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/rules/foot.md" <<'MD'
---
description: A rule with a footer.
---

# Footer Rule

- MUST do x

## Related Documentation

- [x](y.md)
MD
	run bash "${V}" "${p}/.rulesync/rules/foot.md"
	assert_status 0
	assert_contains "${output}" "FORBIDDEN FOOTER"
}

@test "toolsmith validate: the same heading inside a fenced example is left alone" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/rules/fenced.md" <<'MD'
---
description: A rule showing the convention.
---

# Fenced Example Rule

Every human doc ends with:

```markdown
## Related Documentation

- [x](y.md)
```
MD
	run bash "${V}" "${p}/.rulesync/rules/fenced.md"
	assert_status 0
	assert_not_contains "${output}" "FORBIDDEN FOOTER"
}

# ------------------------------------------------ (f) skill discoverability ---

@test "toolsmith validate: a skill with no description is unfindable, and told so" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/skills/foo/SKILL.md" <<'MD'
---
name: foo
---

# Foo
MD
	run bash "${V}" "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "MISSING DESCRIPTION"
}

@test "toolsmith validate: a triggers block is reported as the dead field it is" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/skills/foo/SKILL.md" <<'MD'
---
name: foo
description: Use when foo.
metadata:
    triggers:
        - foo
        - bar
---

# Foo
MD
	run bash "${V}" "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "DEAD FIELD"
}

# ------------------------------------------- (g) the generated-path inversion --

@test "toolsmith validate: a generated copy is flagged and names the layout's own sync command" {
	local p
	p="$(project rulesync-layout)"
	clean_skill "${p}/.rulesync/skills/foo/SKILL.md"
	mkdir -p "${p}/.claude/skills/foo"
	cp "${p}/.rulesync/skills/foo/SKILL.md" "${p}/.claude/skills/foo/SKILL.md"

	run bash "${V}" "${p}/.claude/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "GENERATED PATH"
	# The remedy is the project's own command, read off its profile.
	assert_contains "${output}" "fixture-sync --all"

	run bash "${V}" "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_not_contains "${output}" "GENERATED PATH"
	assert_contains "${output}" "lint clean"
}

@test "toolsmith validate: the SAME path is the authoring source in a layout that generates nothing" {
	local p
	p="$(project plain-agent)"
	clean_skill "${p}/.claude/skills/foo/SKILL.md"
	run bash "${V}" "${p}/.claude/skills/foo/SKILL.md"
	assert_status 0
	assert_not_contains "${output}" "GENERATED PATH"
	assert_contains "${output}" "lint clean"
}

@test "toolsmith validate: a plugin layout lints its shipped commands directory" {
	local p
	p="$(project plugin-layout)"
	write "${p}/commands/broken.md" <<'MD'
no frontmatter here
MD
	run bash "${V}" "${p}/commands/broken.md"
	assert_status 0
	assert_contains "${output}" "(command)"
	assert_contains "${output}" "FRONTMATTER BROKEN"
}

# ------------------------------------------------------------ (h) the no-ops --

@test "toolsmith validate: a path under no layer directory is a silent no-op" {
	local p
	p="$(project rulesync-layout)"
	mkdir -p "${p}/stories"
	printf 'name: x\n' >"${p}/stories/x.yaml"
	run bash "${V}" "${p}/stories/x.yaml"
	assert_status 0
	[ -z "${output}" ]
}

@test "toolsmith validate: a file in a project with no layout at all is a no-op, never a failure" {
	mkdir -p "${FIXROOT}/unmarked/deep"
	printf -- '---\nname: x\n---\n' >"${TMP}/loose.md"
	run bash "${V}" "${TMP}/loose.md"
	assert_status 0
	[ -z "${output}" ]
}

# -------------------------------------------------------------- (i) the modes --

@test "toolsmith validate: audit mode reports the same violations under its own framing" {
	local p
	p="$(project rulesync-layout)"
	write "${p}/.rulesync/skills/foo/SKILL.md" <<'MD'
not-a-fence
name: foo

MUST invoke the nonexistent-thing skill.
MD
	run bash "${V}" --audit "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "AUDIT REPORT"
	assert_contains "${output}" "FRONTMATTER BROKEN"
	assert_contains "${output}" "DANGLING SKILL REF"
}

@test "toolsmith validate: audit mode on a conformant layer says so" {
	local p
	p="$(project rulesync-layout)"
	clean_skill "${p}/.rulesync/skills/foo/SKILL.md"
	run bash "${V}" --audit "${p}/.rulesync/skills/foo/SKILL.md"
	assert_status 0
	assert_contains "${output}" "AUDIT CONFORMANT"
}

@test "toolsmith validate: retire mode lists the layout's own files and deletes nothing" {
	local p
	p="$(project rulesync-layout)"
	clean_skill "${p}/.rulesync/skills/footool/SKILL.md"
	printf -- '---\ndescription: A command.\n---\n' >"${p}/.rulesync/commands/footool.md"
	printf -- '---\ndescription: An agent.\n---\n' >"${p}/.rulesync/subagents/footool.md"
	printf -- '---\ndescription: A rule.\n---\n' >"${p}/.rulesync/rules/footool.md"

	run bash "${V}" --retire footool "${p}"
	assert_status 0
	assert_contains "${output}" "RETIRE (dry-run"
	assert_contains "${output}" "would delete"
	assert_contains "${output}" ".rulesync/skills/footool/"
	assert_contains "${output}" ".rulesync/commands/footool.md"
	assert_contains "${output}" ".rulesync/subagents/footool.md"
	assert_contains "${output}" ".rulesync/rules/footool.md"
	# The generated mirrors are named as the sync's job, never listed for deletion.
	assert_contains "${output}" "are rewritten by fixture-sync --all"

	[ -f "${p}/.rulesync/skills/footool/SKILL.md" ]
	[ -f "${p}/.rulesync/commands/footool.md" ]
	[ -f "${p}/.rulesync/subagents/footool.md" ]
	[ -f "${p}/.rulesync/rules/footool.md" ]
}

@test "toolsmith validate: retire mode in a layout with fewer layers names only the ones it has" {
	local p
	p="$(project plugin-layout)"
	run bash "${V}" --retire packer "${p}"
	assert_status 0
	assert_contains "${output}" "would delete"
	assert_contains "${output}" "skills/packer/"
	# No rules layer, and nothing is generated: neither may be invented.
	assert_not_contains "${output}" "rules/packer"
	assert_not_contains "${output}" "are rewritten by"
}

@test "toolsmith validate: retire mode against a project with no layout says so instead of failing" {
	run bash "${V}" --retire anything "${FIXROOT}/unmarked"
	assert_status 0
	assert_contains "${output}" "no agent-config layout"
}

@test "toolsmith validate: stdin JSON carries the target path as well as an argument does" {
	local p
	p="$(project rulesync-layout)"
	clean_skill "${p}/.rulesync/skills/foo/SKILL.md"
	run bash -c "printf '%s' '{\"tool_input\":{\"file_path\":\"${p}/.rulesync/skills/foo/SKILL.md\"}}' | bash '${V}'"
	assert_status 0
	assert_contains "${output}" "dev-tool lint clean"
}

# ------------------------------------------------------ (j) the shipped set ---

@test "toolsmith validate: every scaffold this plugin ships lints clean" {
	local layout file
	for layout in rulesync plugin plain; do
		for file in "${TEMPLATES}/${layout}"/*.tmpl; do
			run bash "${V}" "${file}"
			assert_status 0
			assert_contains "${output}" "lint clean"
		done
	done
	run bash "${V}" "${TEMPLATES}/script.sh.tmpl"
	assert_status 0
	assert_contains "${output}" "lint clean"
}

@test "toolsmith validate: both skills this plugin ships lint clean" {
	local file
	for file in "${PLUGIN}/skills/dev-tool-authoring/SKILL.md" \
		"${PLUGIN}/skills/skill-discovery/SKILL.md"; do
		run bash "${V}" "${file}"
		assert_status 0
		assert_contains "${output}" "lint clean"
	done
}
