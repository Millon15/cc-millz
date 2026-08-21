#!/usr/bin/env bats
#
# tests/test-phpstorm-xdebug-doctor.bats
#
# xdebug-doctor.sh has a real CLI boundary, so it is driven rather than grepped.
# The checks themselves need a live container runtime and a running IDE, so the
# fixture ships stub `docker`, `pgrep` and `lsof` executables and this suite
# prepends them to PATH: what is asserted is the doctor's own logic — which row
# it checks, which fix it prints, and what it refuses — not the runtime's.
#
# The origin of this suite pinned its assertions to the service names of one
# private monorepo. Every one of them is now keyed on tests/fixtures/phpstorm/
# instead, so the suite proves the profile is being read rather than that a
# hard-coded array is still in place.
#
# The shipped command is markdown with no CLI boundary of its own, so the last
# section greps its body for the two claims a run cannot show.

setup_file() {
	export FIXROOT="${BATS_FILE_TMPDIR}/fixtures"
	mkdir -p "${FIXROOT}"
	bash "${BATS_TEST_DIRNAME}/fixtures/phpstorm/setup.sh" "${FIXROOT}" >/dev/null
}

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck source=/dev/null
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	PLUGIN="${REPO_ROOT}/plugins/phpstorm"
	DOCTOR="${PLUGIN}/scripts/xdebug-doctor.sh"
	CMD_FILE="${PLUGIN}/commands/setup-xdebug.md"
	FIXTURES="${REPO_ROOT}/tests/fixtures/phpstorm"
	GREEN="${FIXROOT}/green"
	MINIMAL="${FIXROOT}/minimal"
	BARE="${FIXROOT}/bare"
	# The container and port tools the checks shell out to.
	PATH="${FIXTURES}/stub-bin:${PATH}"
	export PATH
}

teardown() { teardown_tmp; }

# ------------------------------------------------------------- the package --

@test "phpstorm: the plugin manifest is 0.2.0 with an empty dependencies field" {
	run jq -r '.name, .version' "${PLUGIN}/.claude-plugin/plugin.json"
	assert_status 0
	assert_contains "${output}" "phpstorm"
	assert_contains "${output}" "0.2.0"
	[ "$(jq -r '.dependencies | length' "${PLUGIN}/.claude-plugin/plugin.json")" = "0" ]
}

@test "phpstorm: the doctor ships executable inside the plugin" {
	[ -x "${DOCTOR}" ]
	[ -f "${CMD_FILE}" ]
}

@test "phpstorm: the provenance sentence is carried by the catalogue surfaces" {
	local sentence="Extracted from a private monorepo."
	assert_contains "$(jq -r '.plugins[] | select(.name == "phpstorm") | .description' "${REPO_ROOT}/.claude-plugin/marketplace.json")" "${sentence}"
	assert_contains "$(cat "${PLUGIN}/README.md")" "${sentence}"
	assert_contains "$(sed -n '/^## phpstorm v/,/^## [a-z]/p' "${REPO_ROOT}/CHANGELOG.md")" "${sentence}"
	grep -q 'phpstorm' "${REPO_ROOT}/README.md"
}

@test "phpstorm: the basename setup-xdebug is unique across every plugin's commands" {
	local dupes
	dupes="$(cd "${REPO_ROOT}" && find plugins -path '*/commands/*' -name '*.md' -exec basename {} \; | sort | uniq -d)"
	[ -z "${dupes}" ] || {
		printf 'duplicate command basenames across plugins: %s\n' "${dupes}" >&2
		return 1
	}
	# Uniqueness over a one-plugin set proves nothing; the claim is about four.
	local plugins_with_commands
	plugins_with_commands="$(cd "${REPO_ROOT}" && find plugins -path '*/commands/*' -name '*.md' | cut -d/ -f2 | sort -u | wc -l | tr -d ' ')"
	[ "${plugins_with_commands}" -ge 4 ]
	[ "$(cd "${REPO_ROOT}" && find plugins -path '*/commands/*' -name 'setup-xdebug.md' | wc -l | tr -d ' ')" = "1" ]
}

# ------------------------------------------------------------ the argument --

@test "xdebug-doctor: --help prints usage and the profile shape, exits 2" {
	run bash "${DOCTOR}" --help
	assert_status 2
	assert_contains "${output}" "usage:"
	assert_contains "${output}" ".xdebug-doctor.json"
}

@test "xdebug-doctor: unknown service is rejected with exit 2, never a green verdict" {
	run bash "${DOCTOR}" --root "${GREEN}" bogus-service
	assert_status 2
	assert_contains "${output}" "unknown service"
	assert_not_contains "${output}" "All checks passed"
}

@test "xdebug-doctor: a grep-style pattern is not a service name" {
	# `a.p` matches the declared `app` as a pattern but no row exactly — it must
	# be rejected, not silently skip every check.
	run bash "${DOCTOR}" --root "${GREEN}" "a.p"
	assert_status 2
	assert_contains "${output}" "unknown service"
}

@test "xdebug-doctor: rejection lists the services the profile declares" {
	run bash "${DOCTOR}" --root "${GREEN}" bogus-service
	assert_status 2
	assert_contains "${output}" "services: app"
}

@test "xdebug-doctor: an unknown flag is a usage error" {
	run bash "${DOCTOR}" --root "${GREEN}" --nope
	assert_status 2
	assert_contains "${output}" "unknown argument"
}

# -------------------------------------------------------------- the profile --

@test "xdebug-doctor: no profile exits 2 naming the marker, never a green verdict" {
	run bash "${DOCTOR}" --root "${BARE}"
	assert_status 2
	assert_contains "${output}" ".xdebug-doctor.json"
	assert_not_contains "${output}" "All checks passed"
}

@test "xdebug-doctor: an unreadable profile exits 2 rather than falling through" {
	local broken="${TMP}/broken"
	mkdir -p "${broken}"
	printf 'not json at all\n' >"${broken}/.xdebug-doctor.json"
	run bash "${DOCTOR}" --explain --root "${broken}"
	assert_status 2
	assert_contains "${output}" "not readable JSON"
}

@test "xdebug-doctor: a profile with no services exits 2" {
	local empty="${TMP}/empty"
	mkdir -p "${empty}"
	printf '{"services": []}\n' >"${empty}/.xdebug-doctor.json"
	run bash "${DOCTOR}" --explain --root "${empty}"
	assert_status 2
	assert_contains "${output}" "no services array"
}

@test "xdebug-doctor: a service missing a required field is named, not half-checked" {
	local partial="${TMP}/partial"
	mkdir -p "${partial}"
	printf '{"services": [{"name": "app", "port": 9003, "server_name": "app.local"}]}\n' >"${partial}/.xdebug-doctor.json"
	run bash "${DOCTOR}" --explain --root "${partial}"
	assert_status 2
	assert_contains "${output}" "app"
}

# -------------------------------------------------------------- the explain --

@test "xdebug-doctor: --explain reports the declared rows as profile" {
	run bash "${DOCTOR}" --explain --root "${GREEN}"
	assert_status 0
	assert_explain_complete "${output}"
	assert_explain_source "${output}" services profile
	assert_explain_source "${output}" start_cmd profile
	assert_explain_source "${output}" workspace_file default
	[ "$(printf '%s' "${output}" | jq -r '.plugin')" = "phpstorm" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.services.app.container')" = "demo-app-1" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.services.app.port')" = "9003" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.services.app.remote_root')" = "/var/www/app" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.start_cmd')" = "make up SERVICE={service}" ]
	[ "$(printf '%s' "${output}" | jq -r '.values.workspace_file')" = ".idea/workspace.xml" ]
}

@test "xdebug-doctor: without the optional keys both fall back to their defaults" {
	run bash "${DOCTOR}" --explain --root "${MINIMAL}"
	assert_status 0
	assert_explain_complete "${output}"
	assert_explain_source "${output}" services profile
	assert_explain_source "${output}" start_cmd default
	assert_explain_source "${output}" workspace_file default
	[ "$(printf '%s' "${output}" | jq -r '.values.start_cmd')" = "docker compose up -d {service}" ]
	# An absent mapping is null, never a guess.
	[ "$(printf '%s' "${output}" | jq -r '.values.services.app.host_dir')" = "null" ]
}

@test "xdebug-doctor: the profile is found by walking up from a subdirectory" {
	run bash "${DOCTOR}" --explain --root "${GREEN}/sub"
	assert_status 0
	assert_contains "$(printf '%s' "${output}" | jq -r '.profile_file')" ".xdebug-doctor.json"
	assert_explain_source "${output}" services profile
}

@test "xdebug-doctor: --explain with a service scopes the answer to that row" {
	run bash "${DOCTOR}" --explain --root "${GREEN}" app
	assert_status 0
	[ "$(printf '%s' "${output}" | jq -r '.values.services | keys | join(",")')" = "app" ]

	run bash "${DOCTOR}" --explain --root "${GREEN}" bogus-service
	assert_status 2
}

# ---------------------------------------------------------------- the checks --

@test "xdebug-doctor: a healthy fixture project passes every check" {
	run bash "${DOCTOR}" --root "${GREEN}"
	assert_status 0
	assert_contains "${output}" "All checks passed"
	assert_contains "${output}" "app (demo-app-1)"
	assert_contains "${output}" "client_port = 9003"
	assert_contains "${output}" "mapping app → /var/www/app"
	# The closing pointer is the plugin's own skill, not a project's.
	assert_contains "${output}" "phpstorm:phpstorm-debug"
}

@test "xdebug-doctor: a stopped container is fixed with the profile's start_cmd, service substituted" {
	export STUB_DOCKER_PS=""
	run bash "${DOCTOR}" --root "${GREEN}"
	assert_status 1
	assert_contains "${output}" "container not running"
	assert_contains "${output}" "make up SERVICE=app"
}

@test "xdebug-doctor: without a declared start_cmd the fix is the default, service substituted" {
	run bash "${DOCTOR}" --root "${MINIMAL}"
	assert_status 1
	assert_contains "${output}" "container not running"
	assert_contains "${output}" "docker compose up -d app"
}

@test "xdebug-doctor: a wrong client_port is reported against the declared port" {
	export STUB_DOCKER_EXEC="1|client_host=host.docker.internal client_port=9999|1|serverName=app.local"
	run bash "${DOCTOR}" --root "${GREEN}"
	assert_status 1
	assert_contains "${output}" "client_port = '9999', expected 9003"
}

@test "xdebug-doctor: a wrong serverName is reported against the declared one" {
	export STUB_DOCKER_EXEC="1|client_host=host.docker.internal client_port=9003|1|serverName=other.local"
	run bash "${DOCTOR}" --root "${GREEN}"
	assert_status 1
	assert_contains "${output}" "expected serverName=app.local"
}

@test "xdebug-doctor: a closed IDE and a silent debug port are both named" {
	export STUB_IDE_RUNNING=0
	export STUB_IDE_PORT=""
	run bash "${DOCTOR}" --root "${GREEN}"
	assert_status 1
	assert_contains "${output}" "IDE not running"
}

@test "xdebug-doctor: the IDE listening on another port is a failure, not a pass" {
	export STUB_IDE_PORT=9999
	run bash "${DOCTOR}" --root "${GREEN}"
	assert_status 1
	assert_contains "${output}" "IDE not listening on 9003"
}

@test "xdebug-doctor: a missing workspace file is reported at the declared path" {
	run bash "${DOCTOR}" --root "${MINIMAL}"
	assert_status 1
	assert_contains "${output}" ".idea/workspace.xml missing"
}

@test "xdebug-doctor: force-break left on is a failure with the IDE path to fix it" {
	local flagged="${TMP}/flagged"
	mkdir -p "${flagged}/.idea"
	cp "${GREEN}/.xdebug-doctor.json" "${flagged}/.xdebug-doctor.json"
	sed 's/xdebug_force_break_when_no_path_mapping="false"/xdebug_force_break_when_no_path_mapping="true"/' \
		"${GREEN}/.idea/workspace.xml" >"${flagged}/.idea/workspace.xml"
	run bash "${DOCTOR}" --root "${flagged}"
	assert_status 1
	assert_contains "${output}" "xdebug_force_break_when_no_path_mapping is not false"
}

# --------------------------------------------------------- the shipped body --

@test "setup-xdebug: the body resolves the profile through the entry script first" {
	local body
	body="$(cat "${CMD_FILE}")"
	assert_contains "${body}" '${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh" --explain'
	assert_contains "${body}" '## Phase 0 — Resolve the project profile (ALWAYS FIRST)'
	assert_contains "${body}" 'values.services'
	assert_contains "${body}" 'values.start_cmd'
}

@test "setup-xdebug: every reference to the doctor carries CLAUDE_PLUGIN_ROOT" {
	# A bare scripts/<name>.sh reference does not survive a staging rewrite that
	# keys on ${CLAUDE_PLUGIN_ROOT}: it would ship pointing at nothing.
	local line
	while IFS= read -r line; do
		case "${line}" in
		*'${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh'*) ;;
		*)
			printf 'unprefixed script reference: %s\n' "${line}" >&2
			return 1
			;;
		esac
	done < <(grep -n 'scripts/xdebug-doctor.sh' "${CMD_FILE}")
}

@test "setup-xdebug: the body hard-codes no stack start command anywhere" {
	# The start command comes from --explain and nowhere else, so the command
	# and the doctor cannot disagree about how this project starts.
	local hit
	for hit in 'docker compose up' 'docker-compose up' 'podman compose up' 'make up' 'vagrant up'; do
		assert_not_contains "$(cat "${CMD_FILE}")" "${hit}"
	done
	assert_contains "$(cat "${CMD_FILE}")" 'run the `values.start_cmd` from Phase 0'
}
