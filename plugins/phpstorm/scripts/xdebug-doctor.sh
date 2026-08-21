#!/usr/bin/env bash
#
# xdebug-doctor.sh — verify the local Xdebug ⇄ PhpStorm wiring for every service
# the consuming project declares.
#
#   xdebug-doctor.sh                      # check every declared service
#   xdebug-doctor.sh <service>            # check one
#   xdebug-doctor.sh --explain [<service>] # print the resolved profile as JSON
#   xdebug-doctor.sh --root <dir> …       # treat <dir> as the project root
#
# Exit-code contract: 0 = all checks pass / 1 = at least one FAIL / 2 = usage,
# unreadable profile, or nothing declared to check.
#
# WHY THIS EXISTS:
#   Three independent misconfigurations all produce the SAME symptom —
#   "Debug session was finished without being paused". Telling them apart by
#   hand costs hours; this prints which one is actually broken.
#
# WHERE THE SERVICES COME FROM:
#   A committed .xdebug-doctor.json at the consuming project's root, per the
#   repo-wide --explain contract in CLAUDE.md. Container names, debug ports,
#   server names and path mappings are project facts; there is nothing honest
#   to detect and no default worth guessing, so an absent profile exits 2
#   naming the marker rather than printing a green verdict over zero checks.
#
# SAFETY:
#   Every `docker exec` passes -e XDEBUG_MODE=off. With start_with_request=1 and
#   the IDE listening, an un-guarded `docker exec php` SUSPENDS at line 1 and
#   hangs until timeout — the doctor must never hang on the fault it diagnoses.

set -uo pipefail

readonly PLUGIN=phpstorm
readonly PROFILE_BASENAME=.xdebug-doctor.json
readonly DEFAULT_WORKSPACE_FILE=".idea/workspace.xml"
readonly DEFAULT_START_CMD='docker compose up -d {service}'

usage() {
	cat <<EOF
usage: xdebug-doctor.sh [--explain] [--root <dir>] [<service>]

  <service>       check one declared service instead of every one
  --explain       print the resolved configuration as JSON and exit
  --root <dir>    treat <dir> as the project root (default: the working directory)

Services come from a committed ${PROFILE_BASENAME} at the project root:

  {
    "start_cmd": "docker compose up -d {service}",
    "workspace_file": ".idea/workspace.xml",
    "services": [
      {
        "name": "app",
        "container": "app-1",
        "port": 9003,
        "server_name": "app.local",
        "host_dir": "app",
        "remote_root": "/var/www/app"
      }
    ]
  }

Exit codes: 0 all checks pass · 1 a check failed · 2 usage or unreadable profile.
EOF
}

die() {
	printf 'xdebug-doctor: %s\n' "$1" >&2
	exit 2
}

# The profile belongs at the consuming project's root, but the doctor may be
# invoked from a subdirectory of it, so the search walks up.
find_profile() {
	local dir="$1"
	while :; do
		if [[ -f "${dir}/${PROFILE_BASENAME}" ]]; then
			printf '%s\n' "${dir}/${PROFILE_BASENAME}"
			return 0
		fi
		[[ "${dir}" == "/" ]] && return 1
		dir="$(dirname "${dir}")"
	done
}

# `{service}` is substituted so one declared command covers every service. A
# start command with no placeholder is used verbatim.
render_start_cmd() {
	printf '%s\n' "${START_CMD//\{service\}/$1}"
}

service_names() {
	local row
	for row in "${SERVICES[@]}"; do
		printf '%s ' "${row%%$'\t'*}"
	done
}

is_known_service() {
	local row
	for row in "${SERVICES[@]}"; do
		[[ "${row%%$'\t'*}" == "$1" ]] && return 0
	done
	return 1
}

# ------------------------------------------------------------------- args ---

explain=0
root=""
FILTER=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--explain) explain=1 ;;
	--root)
		root="${2:-}"
		shift
		;;
	-h | --help)
		usage
		exit 2
		;;
	-*) die "unknown argument: $1" ;;
	*)
		[[ -n "${FILTER}" ]] && die "one service at a time, got: ${FILTER} and $1"
		FILTER="$1"
		;;
	esac
	shift
done

command -v jq >/dev/null 2>&1 || die 'jq is required and is not on PATH'

root="${root:-${PWD}}"
[[ -d "${root}" ]] || die "no such directory: ${root}"
root="$(cd "${root}" && pwd)"

# ---------------------------------------------------------------- profile ---

profile_file="$(find_profile "${root}" || true)"
if [[ -z "${profile_file}" ]]; then
	die "nothing to check at ${root}.
Looked for a committed ${PROFILE_BASENAME} at the project root or above; none is
present. Container names, debug ports and path mappings are project facts with
nothing to detect — write the profile (see --help for its shape)."
fi

jq -e . "${profile_file}" >/dev/null 2>&1 ||
	die "profile is not readable JSON: ${profile_file}"
jq -e '(.services | type) == "array" and (.services | length) > 0' "${profile_file}" >/dev/null 2>&1 ||
	die "profile declares no services array: ${profile_file}"

incomplete="$(jq -r '[.services[]
    | select((.name | type) != "string"
          or (.container | type) != "string"
          or (.port == null)
          or (.server_name | type) != "string")
    | (.name // "<unnamed>")] | join(", ")' "${profile_file}")"
[[ -n "${incomplete}" ]] &&
	die "every service needs name, container, port and server_name — incomplete: ${incomplete}"

# The consuming project's root is where the profile sits, not where the doctor
# was invoked: the workspace file and the path mappings are relative to it.
root="$(cd "$(dirname "${profile_file}")" && pwd)"
cd "${root}" || exit 2

WORKSPACE_FILE="$(jq -r '.workspace_file // empty' "${profile_file}")"
WORKSPACE_FILE_SOURCE=profile
if [[ -z "${WORKSPACE_FILE}" ]]; then
	WORKSPACE_FILE="${DEFAULT_WORKSPACE_FILE}"
	WORKSPACE_FILE_SOURCE=default
fi

START_CMD="$(jq -r '.start_cmd // empty' "${profile_file}")"
START_CMD_SOURCE=profile
if [[ -z "${START_CMD}" ]]; then
	START_CMD="${DEFAULT_START_CMD}"
	START_CMD_SOURCE=default
fi

# name<TAB>container<TAB>port<TAB>server<TAB>host_dir<TAB>remote_root
SERVICES=()
while IFS= read -r line; do
	[[ -n "${line}" ]] && SERVICES+=("${line}")
done < <(jq -r '.services[] | [.name, .container, (.port | tostring), .server_name,
    (.host_dir // ""), (.remote_root // "")] | @tsv' "${profile_file}")

# A filter that matches no row would skip every check and still print the green
# verdict — an all-clear from the tool whose whole job is telling three
# identical-looking misconfigurations apart. Reject the typo instead. Compared
# exactly, like the per-service loop does: a `grep` pattern lets `f.ont` past
# the guard and then match no row.
if [[ -n "${FILTER}" ]] && ! is_known_service "${FILTER}"; then
	printf '\033[31munknown service:\033[0m %s\n' "${FILTER}" >&2
	printf 'services: %s\n' "$(service_names)" >&2
	exit 2
fi

# ---------------------------------------------------------------- explain ---

if [[ ${explain} -eq 1 ]]; then
	jq -n \
		--arg plugin "${PLUGIN}" \
		--arg profile_file "${profile_file}" \
		--arg filter "${FILTER}" \
		--argjson services "$(jq '[.services[] | {key: .name, value: {
            container: .container,
            port: .port,
            server_name: .server_name,
            host_dir: (.host_dir // null),
            remote_root: (.remote_root // null)
        }}] | from_entries' "${profile_file}")" \
		--arg start_cmd "${START_CMD}" \
		--arg start_cmd_source "${START_CMD_SOURCE}" \
		--arg workspace_file "${WORKSPACE_FILE}" \
		--arg workspace_file_source "${WORKSPACE_FILE_SOURCE}" '
        {
            plugin: $plugin,
            profile_file: $profile_file,
            values: {
                services: (if $filter == "" then $services
                           else ($services | with_entries(select(.key == $filter))) end),
                start_cmd: $start_cmd,
                workspace_file: $workspace_file
            },
            sources: {
                services: "profile",
                start_cmd: $start_cmd_source,
                workspace_file: $workspace_file_source
            }
        }'
	exit 0
fi

# ----------------------------------------------------------------- output ---

fails=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() {
	printf '  \033[31m✗\033[0m %s\n     \033[33m↳ fix:\033[0m %s\n' "$1" "$2"
	fails=$((fails + 1))
}
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- IDE checks
head2 "PhpStorm"

ide_running=0
for name in phpstorm PhpStorm phpstorm64; do
	pgrep -x "$name" >/dev/null 2>&1 && ide_running=1 && break
done

if [[ ${ide_running} -eq 1 ]]; then
	pass "IDE process running"
else
	fail "IDE not running" "start PhpStorm — without it there is no debugger to attach to"
fi

listening_ports=""
if command -v lsof >/dev/null 2>&1; then
	listening_ports=$(lsof -iTCP -sTCP:LISTEN -n -P +c 0 2>/dev/null |
		awk 'tolower($1) ~ /phpstorm/ {print $(NF-1)}' |
		sed -nE 's#.*:([0-9]+)$#\1#p' | sort -un | tr '\n' ' ')
else
	warn "lsof unavailable — cannot verify listening ports"
fi

# ------------------------------------------------------- IDE debug settings
head2 "Debug settings (${WORKSPACE_FILE})"

if [[ ! -f "${WORKSPACE_FILE}" ]]; then
	fail "${WORKSPACE_FILE} missing" "open the project in PhpStorm once, then re-run"
else
	for flag in xdebug_force_break_when_no_path_mapping xdebug_force_break_when_outside_project; do
		if grep -q "${flag}=\"false\"" "${WORKSPACE_FILE}"; then
			pass "$flag = false"
		else
			fail "$flag is not false" \
				"Settings │ PHP │ Debug → Xdebug: uncheck 'Force break at first line …'. Leaving it on suspends EVERY container php process at line 1."
		fi
	done
fi

# --------------------------------------------------------------- per service
# Space-delimited set of already-reported servers. A plain string, not an
# associative array: macOS ships bash 3.2, which has no `declare -A`.
SEEN_SERVERS=""

for row in "${SERVICES[@]}"; do
	IFS=$'\t' read -r name container port server host_dir remote_root <<<"${row}"
	[[ -n "${FILTER}" && "${FILTER}" != "${name}" ]] && continue

	head2 "$name ($container)"

	if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
		fail "container not running" "$(render_start_cmd "${name}")"
		continue
	fi
	pass "container running"

	# XDEBUG_MODE=off keeps this exec from suspending on a mis-set force-break.
	#
	# Read client_host/client_port from the XDEBUG_CONFIG **env var**, not from
	# ini_get: with mode=off Xdebug skips parsing XDEBUG_CONFIG entirely, so
	# ini_get would report the compiled default (9003) and every service would
	# be flagged as misconfigured. start_with_request comes from php.ini and
	# reads correctly either way.
	ini=$(docker exec -e XDEBUG_MODE=off "$container" php -r \
		'echo implode("|",[extension_loaded("xdebug")?"1":"0",getenv("XDEBUG_CONFIG"),ini_get("xdebug.start_with_request"),getenv("PHP_IDE_CONFIG")]);' 2>/dev/null)

	if [[ -z "$ini" ]]; then
		fail "cannot read PHP config" "docker exec -e XDEBUG_MODE=off $container php -v"
		continue
	fi

	IFS='|' read -r has_xdebug xdebug_config swr ide_config <<<"$ini"
	client_host=$(printf '%s' "$xdebug_config" | sed -nE 's/.*client_host=([^ ]+).*/\1/p')
	client_port=$(printf '%s' "$xdebug_config" | sed -nE 's/.*client_port=([0-9]+).*/\1/p')

	if [[ "$has_xdebug" == "1" ]]; then
		pass "xdebug extension loaded"
	else
		fail "xdebug NOT loaded" "rebuild the image behind $container — its php.ini must load xdebug.so"
	fi

	if [[ "$client_host" == "host.docker.internal" ]]; then
		pass "client_host = $client_host"
	else
		fail "client_host = '$client_host'" "set XDEBUG_CONFIG client_host=host.docker.internal for $container"
	fi

	if [[ "$client_port" == "$port" ]]; then
		pass "client_port = $port"
	else
		fail "client_port = '$client_port', expected $port" "fix XDEBUG_CONFIG client_port for $container"
	fi

	if [[ "$swr" == "1" || "$swr" == "yes" ]]; then
		pass "start_with_request = $swr"
	else
		warn "start_with_request = '$swr' — requests will not auto-attach; trigger manually"
	fi

	if [[ "$ide_config" == "serverName=$server" ]]; then
		pass "PHP_IDE_CONFIG = $ide_config"
	else
		fail "PHP_IDE_CONFIG = '$ide_config', expected serverName=$server" \
			"set PHP_IDE_CONFIG=serverName=$server for $container"
	fi

	if [[ -n "$listening_ports" ]]; then
		if [[ " $listening_ports " == *" $port "* ]]; then
			pass "IDE listening on $port"
		else
			fail "IDE not listening on $port" \
				"click the phone icon (Start Listening for PHP Debug Connections), or add $port to Settings │ PHP │ Debug → Xdebug → Debug port"
		fi
	fi

	# Server entry + mapping — shared across services, so report each server once.
	if [[ -f "${WORKSPACE_FILE}" && " $SEEN_SERVERS " != *" $server "* ]]; then
		SEEN_SERVERS="$SEEN_SERVERS $server"
		if grep -q "name=\"$server\"" "${WORKSPACE_FILE}"; then
			pass "server '$server' defined"
		else
			fail "server '$server' NOT defined" \
				"Settings │ PHP │ Servers → + → name AND host = $server, port 80, debugger Xdebug, tick 'Use path mappings'"
		fi
	fi

	if [[ -f "${WORKSPACE_FILE}" && -n "$host_dir" && -n "$remote_root" ]]; then
		if grep -q "local-root=\"\$PROJECT_DIR\$/$host_dir\" remote-root=\"$remote_root\"" "${WORKSPACE_FILE}"; then
			pass "mapping $host_dir → $remote_root"
		else
			fail "mapping $host_dir → $remote_root missing" \
				"Settings │ PHP │ Servers → '$server' → map project dir '$host_dir' to '$remote_root'"
		fi
	fi
done

# -------------------------------------------------------------------- verdict
if [[ ${fails} -eq 0 ]]; then
	printf '\n\033[32mAll checks passed.\033[0m Set a breakpoint, trigger via docker exec, attach — see the phpstorm:phpstorm-debug skill.\n'
	exit 0
fi

printf '\n\033[31m%d check(s) failed.\033[0m Fix the ↳ items above and re-run.\n' "${fails}"
exit 1
