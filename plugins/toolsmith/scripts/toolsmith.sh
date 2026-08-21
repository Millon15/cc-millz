#!/usr/bin/env bash
#
# toolsmith.sh — resolve the consuming project's agent-config layout and print
# it as JSON. Every other script and command in this plugin calls this FIRST
# and consumes the result, so none of them carries a hard-coded directory.
#
#   toolsmith.sh --explain [--root <dir>]
#
# Three layouts, each selected by a POSITIVE marker, searched from --root
# upwards. No layout is the fallback: a directory carrying none of the markers
# is a usage error, not a default.
#
#   rulesync   a rulesync config file at the root (rulesync.jsonc, .json, .ts,
#              .js, .mjs). Sources live under .rulesync/ and the agent dirs are
#              generated, so the adapter also reports the generated dirs and
#              the staged-plugin registry.
#   plugin     a plugin manifest (.claude-plugin/plugin.json, or a marketplace
#              manifest). Sources ARE the shipped dirs; nothing is generated.
#   plain      any agent-config marker: AGENTS.md, CLAUDE.md, .claude/,
#              .cursor/ or .agents/. Sources live under .claude/.
#
# Resolution, per the repo-wide --explain contract in CLAUDE.md:
#
#   layout, root, the four layer dirs, generated_dirs, vendor_registry and
#   staged_registry      ALWAYS the detected marker — a layout key placed in
#                        the profile is IGNORED, so a repo that changes shape
#                        is right on the next run rather than on the next edit
#   sync_cmd             profile, else null: a layout whose sources are the
#   docs_cmd             shipped files has no sync step, and no default can be
#   knowledge_skill      invented for a project's own docs or knowledge base
#   task_runner          profile, else the build files present at the root,
#                        else an empty ladder
#
# Exit codes: 0 resolved · 2 no layout marker, unreadable profile, or bad usage.

set -euo pipefail

readonly PLUGIN=toolsmith
readonly PROFILE_BASENAME=.toolsmith.json

# A layer a layout does not have is carried through the tab-separated rows as
# this sentinel and reported as null. It cannot be an empty field: a tab is IFS
# whitespace, so `read` collapses a run of them and every later field shifts.
readonly NONE='-'

# ------------------------------------------------------------------ usage ----

usage() {
	cat <<'EOF'
usage: toolsmith.sh --explain [--root <dir>]

  --explain      print the resolved layout as JSON and exit
  --root <dir>   treat <dir> as the project root (default: the working directory);
                 the search walks up from it to the first directory carrying a marker

Exit codes: 0 resolved · 2 no layout marker, unreadable profile, or bad usage.
EOF
}

die() {
	printf 'toolsmith: %s\n' "$1" >&2
	exit 2
}

# ---------------------------------------------------------- layout markers ----

RULESYNC_MARKERS=(rulesync.jsonc rulesync.json rulesync.ts rulesync.js rulesync.mjs)
PLUGIN_MARKERS=(.claude-plugin/plugin.json .claude-plugin/marketplace.json)
PLAIN_MARKERS=(AGENTS.md CLAUDE.md .claude .cursor .agents)

# Prints the layout name when <dir> carries one of that layout's markers.
# Order is the precedence: a rulesync project also has generated agent dirs, so
# testing the plain markers first would classify every one of them as plain.
layout_of() {
	local dir="$1" marker
	for marker in "${RULESYNC_MARKERS[@]}"; do
		if [ -f "${dir}/${marker}" ]; then
			printf 'rulesync\n'
			return 0
		fi
	done
	for marker in "${PLUGIN_MARKERS[@]}"; do
		if [ -f "${dir}/${marker}" ]; then
			printf 'plugin\n'
			return 0
		fi
	done
	for marker in "${PLAIN_MARKERS[@]}"; do
		if [ -e "${dir}/${marker}" ]; then
			printf 'plain\n'
			return 0
		fi
	done
	return 1
}

# The signal each layout was recognised BY — the `detected:<signal>` half of
# every path-shaped key's source, so a reader of the JSON sees which marker
# answered rather than only which layout won.
marker_signal() {
	case "$1" in
	rulesync) printf 'rulesync-config\n' ;;
	plugin) printf 'plugin-manifest\n' ;;
	plain) printf 'agent-marker\n' ;;
	esac
}

# Prints "<layout>\t<root>" for the nearest marked directory at or above <dir>.
# A command may be invoked from anywhere inside the project, so the search walks
# up — but it never invents a layout for a directory that has none.
#
# `plain` is the fallback layout WITHIN a directory and along the walk alike: a
# plain match is remembered, not returned, while a rulesync or plugin marker
# above it still wins. Its markers are satisfied by a file merely NAMED
# AGENTS.md or CLAUDE.md, and a generated-config project holds those as ordinary
# content — a root rule is one — so returning the first plain hit would classify
# a subdirectory of such a project as a plain checkout of its own.
find_layout() {
	local dir="$1" layout plain_root=""
	while :; do
		if layout="$(layout_of "${dir}")"; then
			if [ "${layout}" != plain ]; then
				printf '%s\t%s\n' "${layout}" "${dir}"
				return 0
			fi
			[ -n "${plain_root}" ] || plain_root="${dir}"
		fi
		if [ "${dir}" = "/" ]; then
			break
		fi
		dir="$(dirname "${dir}")"
	done
	[ -n "${plain_root}" ] || return 1
	printf 'plain\t%s\n' "${plain_root}"
}

no_layout() {
	die "no agent-config layout at $1 or above.
Looked for, in this order:
  rulesync layout  ${RULESYNC_MARKERS[*]}
  plugin layout    ${PLUGIN_MARKERS[*]}
  plain layout     ${PLAIN_MARKERS[*]}
None is present. Add the marker its layout expects — for a plain checkout an
AGENTS.md or a .claude/ directory is enough — then run this again."
}

# ------------------------------------------------------------ layer paths ----

# Prints the layer dirs and registries for a layout, tab-separated, in the order
# skills, commands, agents, rules, vendor_registry, staged_registry.
paths_for() {
	case "$1" in
	rulesync)
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			.rulesync/skills .rulesync/commands .rulesync/subagents .rulesync/rules \
			.rulesync/vendored-skills.json .rulesync/.staged-plugins.json
		;;
	plugin)
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			skills commands agents "${NONE}" vendored-skills.json "${NONE}"
		;;
	plain)
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			.claude/skills .claude/commands .claude/agents .claude/rules \
			.claude/vendored-skills.json "${NONE}"
		;;
	esac
}

# The dirs a sync writes, one per line. Only a layout whose sources are separate
# from what the agents read has any: in the other two the sources ARE the files.
generated_for() {
	case "$1" in
	rulesync) printf '%s\n' .claude .cursor .agents .codex .opencode .gemini ;;
	*) : ;;
	esac
}

# ---------------------------------------------------------- the task runner --

# The ladder is what a command offers the user as "how this project is driven".
# Detection reads the build files at the root in a fixed order, so a project
# with both a justfile and a Makefile reports both, in that order.
node_runner() {
	local dir="$1"
	if [ -f "${dir}/bun.lockb" ] || [ -f "${dir}/bun.lock" ]; then
		printf 'bun run\n'
	elif [ -f "${dir}/pnpm-lock.yaml" ]; then
		printf 'pnpm run\n'
	elif [ -f "${dir}/yarn.lock" ]; then
		printf 'yarn run\n'
	else
		printf 'npm run\n'
	fi
}

detect_task_runners() {
	local dir="$1" name
	for name in justfile Justfile .justfile; do
		if [ -f "${dir}/${name}" ]; then
			printf 'just\n'
			break
		fi
	done
	for name in Makefile makefile GNUmakefile; do
		if [ -f "${dir}/${name}" ]; then
			printf 'make\n'
			break
		fi
	done
	if [ -f "${dir}/package.json" ] && jq -e '.scripts' "${dir}/package.json" >/dev/null 2>&1; then
		node_runner "${dir}"
	fi
}

# ------------------------------------------------------------- jq plumbing ---

# Newline-delimited stdin to a compact JSON array. A ladder entry is a whole
# command and may hold spaces, so nothing here ever splits on one.
lines_to_json() {
	jq -R . | jq -s -c .
}

# A path or command to a JSON string, or the JSON null the sentinel stands for.
nullable() {
	if [ -z "$1" ] || [ "$1" = "${NONE}" ]; then
		printf 'null'
	else
		jq -Rn --arg v "$1" '$v'
	fi
}

# ------------------------------------------------------------------ main -----

explain=0
root=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--explain) explain=1 ;;
	--root)
		root="${2:-}"
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

root="${root:-${PWD}}"
if [ ! -d "${root}" ]; then
	die "no such directory: ${root}"
fi
root="$(cd "${root}" && pwd -P)"

found="$(find_layout "${root}" || true)"
if [ -z "${found}" ]; then
	no_layout "${root}"
fi
IFS=$'\t' read -r layout layout_root <<<"${found}"
layout_source="detected:$(marker_signal "${layout}")"

profile_file=""
if [ -f "${layout_root}/${PROFILE_BASENAME}" ]; then
	profile_file="${layout_root}/${PROFILE_BASENAME}"
	jq -e . "${profile_file}" >/dev/null 2>&1 ||
		die "profile is not readable JSON: ${profile_file}"
fi

IFS=$'\t' read -r skills_dir commands_dir agents_dir rules_dir vendor_registry staged_registry \
	< <(paths_for "${layout}")

# A registry the layout defines but the project has not written yet is reported
# as absent, so a caller never opens a file that is not there.
if [ "${staged_registry}" != "${NONE}" ] && [ ! -f "${layout_root}/${staged_registry}" ]; then
	staged_registry="${NONE}"
fi

generated_json="$(generated_for "${layout}" | lines_to_json)"

# The four profile keys. Each is `profile` when the profile carries it, and
# nothing is invented for the three that no signal could detect.
profile_string() {
	if [ -z "${profile_file}" ]; then
		return 0
	fi
	jq -r --arg k "$1" '.[$k] // empty | strings' "${profile_file}"
}

sync_cmd="$(profile_string sync_cmd)"
sync_source=profile
if [ -z "${sync_cmd}" ]; then sync_source=default; fi

docs_cmd="$(profile_string docs_cmd)"
docs_source=profile
if [ -z "${docs_cmd}" ]; then docs_source=default; fi

knowledge_skill="$(profile_string knowledge_skill)"
knowledge_source=profile
if [ -z "${knowledge_skill}" ]; then knowledge_source=default; fi

# The ladder accepts either shape in the profile: one command, or several in
# priority order. Both arrive here as JSON so no separator has to be chosen.
task_json=""
task_source=profile
if [ -n "${profile_file}" ]; then
	task_json="$(jq -c --arg k task_runner '.[$k] // empty | if type == "array" then . else [.] end' "${profile_file}")"
fi
if [ -z "${task_json}" ]; then
	task_json="$(detect_task_runners "${layout_root}" | lines_to_json)"
	task_source=detected:build-files
	if [ "${task_json}" = '[]' ]; then task_source=default; fi
fi

jq -n \
	--arg plugin "${PLUGIN}" \
	--arg profile_file "${profile_file}" \
	--arg layout "${layout}" \
	--arg layout_source "${layout_source}" \
	--arg root "${layout_root}" \
	--arg skills_dir "${skills_dir}" \
	--arg commands_dir "${commands_dir}" \
	--argjson agents_dir "$(nullable "${agents_dir}")" \
	--argjson rules_dir "$(nullable "${rules_dir}")" \
	--argjson vendor_registry "$(nullable "${vendor_registry}")" \
	--argjson staged_registry "$(nullable "${staged_registry}")" \
	--argjson generated_dirs "${generated_json}" \
	--argjson sync_cmd "$(nullable "${sync_cmd}")" \
	--arg sync_source "${sync_source}" \
	--argjson docs_cmd "$(nullable "${docs_cmd}")" \
	--arg docs_source "${docs_source}" \
	--argjson knowledge_skill "$(nullable "${knowledge_skill}")" \
	--arg knowledge_source "${knowledge_source}" \
	--argjson task_runner "${task_json}" \
	--arg task_source "${task_source}" '
    {
        plugin: $plugin,
        profile_file: (if $profile_file == "" then null else $profile_file end),
        values: {
            layout: $layout,
            root: $root,
            skills_dir: $skills_dir,
            commands_dir: $commands_dir,
            agents_dir: $agents_dir,
            rules_dir: $rules_dir,
            generated_dirs: $generated_dirs,
            vendor_registry: $vendor_registry,
            staged_registry: $staged_registry,
            sync_cmd: $sync_cmd,
            docs_cmd: $docs_cmd,
            knowledge_skill: $knowledge_skill,
            task_runner: $task_runner
        },
        sources: {
            layout: $layout_source,
            root: $layout_source,
            skills_dir: $layout_source,
            commands_dir: $layout_source,
            agents_dir: $layout_source,
            rules_dir: $layout_source,
            generated_dirs: $layout_source,
            vendor_registry: $layout_source,
            staged_registry: $layout_source,
            sync_cmd: $sync_source,
            docs_cmd: $docs_source,
            knowledge_skill: $knowledge_source,
            task_runner: $task_source
        }
    }'
