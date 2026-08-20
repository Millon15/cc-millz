#!/usr/bin/env bats
#
# tests/test-merge-kit-commands.bats
#
# The two shipped commands are markdown, so they have no CLI boundary of their
# own: their contract is asserted by grepping the bodies. What a grep cannot
# show is whether the JSON those bodies consume actually carries what they read
# off it, so the second half of this file DRIVES merge-kit.sh over the fixture
# workspace and asserts the two values the commands branch on — the resolved
# test command per repository, and the forge CLI per origin URL.
#
# A static grep is weaker than a run, and it is paired with a captured smoke
# log of the command itself so the claim has an execution behind it.

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
	RESOLVE="$(cat "${PLUGIN}/commands/resolve.md")"
	VERIFY="$(cat "${PLUGIN}/commands/verify.md")"
}

teardown() { teardown_tmp; }

# ------------------------------------------------------------- the package --

@test "merge-kit commands: both bodies ship inside the plugin" {
	[ -f "${PLUGIN}/commands/resolve.md" ]
	[ -f "${PLUGIN}/commands/verify.md" ]
}

@test "merge-kit commands: the plugin is registered in the marketplace catalogue" {
	run jq -r '.plugins[] | select(.name == "merge-kit") | .source' "${REPO_ROOT}/.claude-plugin/marketplace.json"
	assert_status 0
	assert_contains "${output}" "./plugins/merge-kit"
}

@test "merge-kit commands: the provenance sentence is carried by every catalogue surface" {
	local sentence="Extracted from a private monorepo."
	assert_contains "$(jq -r '.plugins[] | select(.name == "merge-kit") | .description' "${REPO_ROOT}/.claude-plugin/marketplace.json")" "${sentence}"
	assert_contains "$(cat "${PLUGIN}/README.md")" "${sentence}"
	assert_contains "$(sed -n '/^## merge-kit v/,/^## [a-z]/p' "${REPO_ROOT}/CHANGELOG.md")" "${sentence}"
	grep -q 'merge-kit' "${REPO_ROOT}/README.md"
}

@test "merge-kit commands: the basenames resolve and verify are unique across every plugin" {
	local dupes
	dupes="$(cd "${REPO_ROOT}" && find plugins -path '*/commands/*' -name '*.md' -exec basename {} \; | sort | uniq -d)"
	[ -z "${dupes}" ] || {
		printf 'duplicate command basenames across plugins: %s\n' "${dupes}" >&2
		return 1
	}
	# The uniqueness claim is only worth asserting while more than one plugin
	# ships commands; guard against it passing on an empty set.
	local plugins_with_commands
	plugins_with_commands="$(cd "${REPO_ROOT}" && find plugins -path '*/commands/*' -name '*.md' | cut -d/ -f2 | sort -u | wc -l | tr -d ' ')"
	[ "${plugins_with_commands}" -ge 4 ]
}

# ------------------------------------------------------ the entry scripts ----

@test "merge-kit commands: each body resolves the profile through the entry script first" {
	assert_contains "${RESOLVE}" '${CLAUDE_PLUGIN_ROOT}/scripts/merge-kit.sh" --explain'
	assert_contains "${VERIFY}" '${CLAUDE_PLUGIN_ROOT}/scripts/merge-kit.sh" --explain'
	# Phase 0 is the first phase in both, so nothing below it can be derived
	# from prose that the profile could have supplied.
	assert_contains "${RESOLVE}" '## Phase 0 — Resolve the project profile (ALWAYS FIRST)'
	assert_contains "${VERIFY}" '## Phase 0 — Resolve the project profile (ALWAYS FIRST)'
}

@test "merge-kit commands: the resolve body wires both forensic phases to --in-progress" {
	local calls
	calls="$(printf '%s\n' "${RESOLVE}" | grep -c -F 'merge-forensics.sh" --repo {REPO_DIR} --in-progress' || true)"
	# One before the walk (what the auto-merge dropped), one before the commit
	# (what survived the whole run). Losing either collapses the safety net.
	[ "${calls}" -ge 2 ] || {
		printf 'expected at least 2 --in-progress forensic calls, found %s\n' "${calls}" >&2
		return 1
	}
	assert_contains "${RESOLVE}" '## Phase 3.5 — Silent-revert audit BEFORE the walk (MANDATORY)'
	assert_contains "${RESOLVE}" '## Phase 5.5 — Forensic verification BEFORE the commit (MANDATORY)'
}

@test "merge-kit commands: the verify body delegates the comparison to the forensic script" {
	assert_contains "${VERIFY}" '${CLAUDE_PLUGIN_ROOT}/scripts/merge-forensics.sh" --repo {REPO_DIR}'
	assert_contains "${VERIFY}" '--in-progress'
	# The squash refusal is surfaced, not worked around: a fabricated fork
	# point produces a confident wrong answer.
	assert_contains "${VERIFY}" 'squash merge: pass --fork or --source'
	assert_contains "${VERIFY}" 'Exit 2 is a usage error, never a verdict'
}

@test "merge-kit commands: both bodies read the verdict from the JSON, not from the exit code" {
	assert_contains "${RESOLVE}" 'the verdict is in the JSON, never in the exit code'
	assert_contains "${VERIFY}" 'the verdict is in the JSON'
}

@test "merge-kit commands: the resolve body cites its prior art" {
	assert_contains "${RESOLVE}" 'mattpocock-skills:resolving-merge-conflicts'
	# Cited as prior art and loaded when present — never a hard dependency.
	assert_contains "${RESOLVE}" 'when it is in the session'"'"'s skill list'
}

# --------------------------------------------------------- profile-driven ----

@test "merge-kit commands: the repository comes from the profile, not from a slug table" {
	assert_contains "${RESOLVE}" 'values.repos[<alias>]'
	assert_contains "${VERIFY}" 'values.repos[<alias>]'
	assert_not_contains "${RESOLVE}" 'bitbucket-repos'
	assert_not_contains "${VERIFY}" 'bitbucket-repos'
	assert_not_contains "${RESOLVE}" 'repo slug'
	assert_not_contains "${VERIFY}" 'repo slug'
}

@test "merge-kit commands: the pull-request fetch branches on the detected forge CLI" {
	local body
	for body in "${RESOLVE}" "${VERIFY}"; do
		assert_contains "${body}" 'values.forge[<alias>]'
		# All three CLIs the detector can produce, plus the honest degrade.
		assert_contains "${body}" '| `gh` |'
		assert_contains "${body}" '| `bbkt` |'
		assert_contains "${body}" '| `glab` |'
		assert_contains "${body}" '| `null` |'
		assert_contains "${body}" 'remote get-url origin'
		assert_contains "${body}" 'never from a hard-coded table'
	done
}

@test "merge-kit commands: the suite comes from the profile with its rung reported" {
	assert_contains "${RESOLVE}" 'values.test_command[<alias>]'
	assert_contains "${RESOLVE}" 'sources.test_command'
	# The null rung asks rather than inventing a command or skipping the phase.
	assert_contains "${RESOLVE}" 'NEVER invent one, and NEVER skip the phase silently'
	# The old body carried a three-row table of one project's own services.
	assert_not_contains "${RESOLVE}" '| LOCAL_DIR | Test command |'
}

@test "merge-kit commands: no project-specific runner survives the extraction" {
	local body
	for body in "${RESOLVE}" "${VERIFY}"; do
		assert_not_contains "${body}" 'qa-plan'
		assert_not_contains "${body}" 'QA stories'
		assert_not_contains "${body}" './12'
	done
	# A broader suite is expressed through the same profile entry.
	assert_contains "${RESOLVE}" 'points its `test_commands` entry at that instead'
}

@test "merge-kit commands: the work directory comes from the profile" {
	assert_contains "${RESOLVE}" 'values.work_dir'
	assert_contains "${VERIFY}" 'values.work_dir'
	assert_not_contains "${RESOLVE}" 'tmp/merge-resolve/{WORK_ID}'
	assert_not_contains "${VERIFY}" 'tmp/merge-verify/{WORK_ID}'
}

# ------------------------------------------------------ language neutrality --

@test "merge-kit commands: the worked sample is language-neutral" {
	# A reader on any stack has to see their own code in the example.
	assert_not_contains "${RESOLVE}" '```php'
	assert_not_contains "${RESOLVE}" '```go'
	assert_not_contains "${RESOLVE}" '```ts'
	assert_contains "${RESOLVE}" 'retry_limit = DEFAULT_RETRY_LIMIT'
	assert_contains "${RESOLVE}" '// ←'
}

@test "merge-kit commands: the trivial tier names no one ecosystem's formatter" {
	assert_contains "${RESOLVE}" 'import-block ordering, formatter alignment'
	assert_not_contains "${RESOLVE}" 'CS-Fixer'
	assert_not_contains "${RESOLVE}" 'cs-fixer'
	# The old OBVIOUS examples were all in one language.
	assert_not_contains "${RESOLVE}" 'ReflectionMethod'
	assert_not_contains "${RESOLVE}" '$price'
}

@test "merge-kit commands: the summary tables carry no one-language file paths" {
	assert_not_contains "${RESOLVE}" 'src/Foo.php'
	assert_not_contains "${RESOLVE}" 'tests/Unit/'
}

# ------------------------------------- what the bodies read off the JSON -----

@test "merge-kit commands: the resolved test command per fixture repo is what the body reads" {
	# repo · expected command · expected rung. The commands print the rung
	# beside the command, so a right value on the wrong rung is still a bug.
	local alias want_cmd want_src got_cmd
	while IFS=$'\t' read -r alias want_cmd want_src; do
		[ -n "${alias}" ] || continue
		run bash "${MK}" --explain --root "${WORKSPACE}" --repo "${alias}"
		assert_status 0
		assert_explain_source "${output}" test_command "${want_src}"
		got_cmd="$(printf '%s' "${output}" | jq -r --arg a "${alias}" '.values.test_command[$a]')"
		[ "${got_cmd}" = "${want_cmd}" ] || {
			printf '%s resolved to %s, expected %s\n' "${alias}" "${got_cmd}" "${want_cmd}" >&2
			return 1
		}
	done <<-'ROWS'
		node-repo	npm test	detected:package-json
		make-repo	make test	detected:makefile
		go-repo	go test ./...	detected:go-mod
		quiet-repo	null	default
	ROWS
}

@test "merge-kit commands: the forge CLI per origin URL is what the fetch table branches on" {
	local n=0 url want got dir
	while read -r url want; do
		case "${url}" in '#'* | '') continue ;; esac
		n=$((n + 1))
		dir="${TMP}/fetch-${n}"
		make_git_repo "${dir}"
		git -C "${dir}" remote add origin "${url}"
		got="$(bash "${MK}" --explain --root "${dir}" | jq -r '.values.forge[]')"
		[ "${want}" = "-" ] && want=null
		[ "${got}" = "${want}" ] || {
			printf '%s resolved to %s, expected %s\n' "${url}" "${got}" "${want}" >&2
			return 1
		}
		# Every CLI the table can be handed must have a row in both bodies,
		# and the unknown host must land on the null row.
		if [ "${want}" != "null" ]; then
			assert_contains "${RESOLVE}" "| \`${want}\` |"
			assert_contains "${VERIFY}" "| \`${want}\` |"
		fi
	done <"${FIXTURES}/origin-urls.txt"
	[ "${n}" -ge 7 ]
}
