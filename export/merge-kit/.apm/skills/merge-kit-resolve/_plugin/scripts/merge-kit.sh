#!/usr/bin/env bash
#
# merge-kit.sh — resolve the consuming project's merge configuration and print
# it as JSON. The markdown commands call this FIRST and consume the result, so
# they never re-derive a repo map, a forge CLI or a test command from prose.
#
#   merge-kit.sh --explain [--root <dir>] [--repo <alias|path>]
#
# Resolution, per the repo-wide --explain contract in CLAUDE.md:
#
#   repos         a committed .merge-kit.json at the project root, else the
#                 `origin` remotes of the working directory and one level of
#                 subdirectories, else exit 2
#   forge         ALWAYS the repo's own `origin` URL — never a profile field,
#                 so a repo that moves between forges is right on the next run
#   test_command  profile override, then a Makefile `test` target, then a
#                 package manager script, then a language default, then null
#   work_dir      profile, else tmp/merge-kit
#
# `--repo` scopes the answer to one repository and is what adds test_command:
# the ladder lands on a different rung per repo, and a single `sources` word
# can only be honest about one of them.

set -euo pipefail

readonly PLUGIN=merge-kit
readonly PROFILE_BASENAME=.merge-kit.json
readonly DEFAULT_WORK_DIR=tmp/merge-kit

# ------------------------------------------------------------------ usage ----

usage() {
	cat <<'EOF'
usage: merge-kit.sh --explain [--root <dir>] [--repo <alias|path>]

  --explain         print the resolved configuration as JSON and exit
  --root <dir>      treat <dir> as the project root (default: the working directory)
  --repo <ref>      scope the answer to one repository, by profile alias or path;
                    adds the resolved test_command and the rung it came from

Exit codes: 0 resolved · 2 unreadable profile, nothing to detect, or bad usage.
EOF
}

die() {
	printf 'merge-kit: %s\n' "$1" >&2
	exit 2
}

# --------------------------------------------------------------- the walk ----

# The profile belongs at the consuming project's root, but a command may be
# invoked from a subdirectory of it, so the search walks up.
find_profile() {
	local dir="$1"
	while :; do
		if [ -f "${dir}/${PROFILE_BASENAME}" ]; then
			printf '%s\n' "${dir}/${PROFILE_BASENAME}"
			return 0
		fi
		if [ "${dir}" = "/" ]; then
			return 1
		fi
		dir="$(dirname "${dir}")"
	done
}

# `git -C <dir>` answers from the nearest enclosing repository, so an ordinary
# subdirectory of a checkout reports that checkout's remote as its own. The
# scan therefore demands the directory BE the repo root, not merely sit inside
# one — otherwise every subdirectory of a monorepo scans as a repo.
is_repo_root() {
	local dir="$1" top
	top="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null || true)"
	[ -n "${top}" ] && [ "${top}" = "$(cd "${dir}" && pwd -P)" ]
}

has_origin() {
	is_repo_root "$1" && git -C "$1" remote get-url origin >/dev/null 2>&1
}

# Every repo the scan finds must have an origin: a directory that is merely a
# git repository says nothing about which forge or which project it belongs to.
scan_repos() {
	local root="$1" dir base
	if has_origin "${root}"; then
		printf '%s\t%s\n' "$(basename "${root}")" "."
	fi
	for dir in "${root}"/*/; do
		if [ ! -d "${dir}" ]; then
			continue
		fi
		if ! has_origin "${dir}"; then
			continue
		fi
		base="$(basename "${dir}")"
		printf '%s\t%s\n' "${base}" "${base}"
	done
}

# ------------------------------------------------------------- the forge -----

# Host first, CLI second. Both SSH shorthand (git@host:owner/repo) and URL
# forms (scheme://user@host/owner/repo) reduce to the same host.
origin_host() {
	local url="$1"
	url="${url#*://}"
	url="${url#*@}"
	url="${url%%/*}"
	url="${url%%:*}"
	printf '%s\n' "${url}"
}

# Prints the CLI, or nothing when the host is one this tool has no CLI for.
forge_for_repo() {
	local dir="$1" url host
	url="$(git -C "${dir}" remote get-url origin 2>/dev/null || true)"
	if [ -z "${url}" ]; then
		return 0
	fi
	host="$(origin_host "${url}")"
	case "${host}" in
	github.com | *.github.com) printf 'gh\n' ;;
	bitbucket.org | *.bitbucket.org) printf 'bbkt\n' ;;
	gitlab.com | *gitlab*) printf 'glab\n' ;;
	*) : ;;
	esac
}

# ------------------------------------------------------- the test command ----

makefile_in() {
	local dir="$1" name
	for name in Makefile makefile GNUmakefile; do
		if [ -f "${dir}/${name}" ]; then
			printf '%s\n' "${dir}/${name}"
			return 0
		fi
	done
	return 1
}

# The package manager comes off the lockfile rather than a guess: running the
# wrong one in a repo that pins its manager fails in a way nobody expects.
node_runner() {
	local dir="$1"
	if [ -f "${dir}/bun.lockb" ] || [ -f "${dir}/bun.lock" ]; then
		printf 'bun run test\n'
	elif [ -f "${dir}/pnpm-lock.yaml" ]; then
		printf 'pnpm test\n'
	elif [ -f "${dir}/yarn.lock" ]; then
		printf 'yarn test\n'
	else
		printf 'npm test\n'
	fi
}

# Prints "<source>\t<command>" — source first because a tab is IFS whitespace,
# so a leading empty field would be eaten on the way back in. A repo with
# nothing to detect prints source `default` and an empty command: the honest
# degrade, which the caller reports rather than papering over.
resolve_test_command() {
	local dir="$1" override="$2" makefile

	if [ -n "${override}" ]; then
		printf 'profile\t%s\n' "${override}"
		return 0
	fi

	if makefile="$(makefile_in "${dir}")" && grep -qE '^test[[:space:]]*:' "${makefile}"; then
		printf 'detected:makefile\tmake test\n'
		return 0
	fi

	if [ -f "${dir}/package.json" ] && jq -e '.scripts.test // empty' "${dir}/package.json" >/dev/null 2>&1; then
		printf 'detected:package-json\t%s\n' "$(node_runner "${dir}")"
		return 0
	fi

	if [ -f "${dir}/go.mod" ]; then
		printf 'detected:go-mod\tgo test ./...\n'
		return 0
	fi

	if [ -f "${dir}/Cargo.toml" ]; then
		printf 'detected:cargo\tcargo test\n'
		return 0
	fi

	if [ -f "${dir}/pyproject.toml" ] || [ -f "${dir}/setup.cfg" ]; then
		printf 'detected:python\tpytest\n'
		return 0
	fi

	printf 'default\t\n'
}

# ------------------------------------------------------------------ main -----

explain=0
root=""
repo_ref=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--explain) explain=1 ;;
	--root)
		root="${2:-}"
		shift
		;;
	--repo)
		repo_ref="${2:-}"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
	shift
done

if [ "${explain}" -ne 1 ]; then
	usage >&2
	exit 2
fi

command -v jq >/dev/null 2>&1 || die 'jq is required and is not on PATH'
command -v git >/dev/null 2>&1 || die 'git is required and is not on PATH'

root="${root:-${PWD}}"
if [ ! -d "${root}" ]; then
	die "no such directory: ${root}"
fi
root="$(cd "${root}" && pwd)"

profile_file="$(find_profile "${root}" || true)"
if [ -n "${profile_file}" ]; then
	jq -e . "${profile_file}" >/dev/null 2>&1 ||
		die "profile is not readable JSON: ${profile_file}"
	root="$(cd "$(dirname "${profile_file}")" && pwd)"
fi

# The repo map: the profile, else the origin scan, else there is no answer.
repos_source=profile
repo_lines=""
if [ -n "${profile_file}" ]; then
	repo_lines="$(jq -r '(.repos // {}) | to_entries[] | "\(.key)\t\(.value)"' "${profile_file}")"
fi
if [ -z "${repo_lines}" ]; then
	repos_source=detected:origin-scan
	repo_lines="$(scan_repos "${root}")"
fi
if [ -z "${repo_lines}" ]; then
	die "nothing to work with at ${root}.
Looked for: a committed ${PROFILE_BASENAME} at the project root or above, then an
'origin' remote on ${root} itself and on each of its immediate subdirectories.
Neither is present. Write a ${PROFILE_BASENAME}:
  {\"repos\": {\"<alias>\": \"<path>\"}, \"test_commands\": {\"<alias>\": \"<command>\"}}"
fi

# --repo scopes the answer, by alias or by the path the alias maps to.
scoped=0
if [ -n "${repo_ref}" ]; then
	scoped=1
	scoped_lines="$(printf '%s\n' "${repo_lines}" |
		awk -F'\t' -v ref="${repo_ref}" '$1 == ref || $2 == ref { print; found = 1 } END { exit !found }')" ||
		die "unknown repo: ${repo_ref}. Known: $(printf '%s\n' "${repo_lines}" | cut -f1 | paste -sd, -)"
	repo_lines="${scoped_lines}"
fi

work_dir="${DEFAULT_WORK_DIR}"
work_dir_source=default
if [ -n "${profile_file}" ]; then
	work_dir_override="$(jq -r '.work_dir // empty' "${profile_file}")"
	if [ -n "${work_dir_override}" ]; then
		work_dir="${work_dir_override}"
		work_dir_source=profile
	fi
fi

rows=""
while IFS=$'\t' read -r name path; do
	if [ -z "${name}" ]; then
		continue
	fi
	case "${path}" in
	/*) abs="${path}" ;;
	.) abs="${root}" ;;
	*) abs="${root}/${path}" ;;
	esac
	forge="$(forge_for_repo "${abs}")"
	test_command=""
	test_source=""
	if [ "${scoped}" -eq 1 ]; then
		override=""
		if [ -n "${profile_file}" ]; then
			override="$(jq -r --arg a "${name}" '.test_commands[$a] // empty' "${profile_file}")"
		fi
		IFS=$'\t' read -r test_source test_command < <(resolve_test_command "${abs}" "${override}")
	fi
	rows+="${name}"$'\t'"${path}"$'\t'"${forge}"$'\t'"${test_command}"$'\t'"${test_source}"$'\n'
done <<<"${repo_lines}"

entries="$(jq -Rn '[inputs | select(length > 0) | split("\t") | {
    alias: .[0],
    path: .[1],
    forge: (if .[2] == "" then null else .[2] end),
    test_command: (if .[3] == "" then null else .[3] end),
    test_source: .[4]
}]' <<<"${rows}")"

jq -n \
	--argjson entries "${entries}" \
	--arg plugin "${PLUGIN}" \
	--arg profile_file "${profile_file}" \
	--arg repos_source "${repos_source}" \
	--arg work_dir "${work_dir}" \
	--arg work_dir_source "${work_dir_source}" \
	--arg scoped "${scoped}" '
    def bykey(f): reduce $entries[] as $e ({}; .[$e.alias] = ($e | f));
    {
        plugin: $plugin,
        profile_file: (if $profile_file == "" then null else $profile_file end),
        values: ({
            repos: bykey(.path),
            forge: bykey(.forge),
            work_dir: $work_dir
        } + (if $scoped == "1" then { test_command: bykey(.test_command) } else {} end)),
        sources: ({
            repos: $repos_source,
            forge: "detected:origin-url",
            work_dir: $work_dir_source
        } + (if $scoped == "1" then { test_command: $entries[0].test_source } else {} end))
    }'
