#!/usr/bin/env bash
#
# vendor-skill.sh — copy a public GitHub skill into this project with provenance.
#
# For a SKILL.md that is not shipped as a plugin. Plugin content is installed
# and refreshed by the plugin system; an upstream skill that ships no plugin has
# to be vendored — committed under our own name, with the source recorded so the
# copy can be refreshed rather than re-found.
#
# Usage:
#   vendor-skill.sh <owner/repo@skill> [--name <local-name>] [--root <dir>]
#   vendor-skill.sh https://github.com/<owner>/<repo>/tree/<ref>/path/to/skill
#   vendor-skill.sh --update <local-name>
#   vendor-skill.sh --list
#
# WHERE the copy lands and WHERE its provenance is recorded both come from
# toolsmith.sh: the skills directory and the record file are the layout's, not
# this script's. Nothing else here knows the project's shape.
#
# Exit-code contract: 0 ok / 1 fetch or copy failure / 2 usage or refusal.
#
# Refuses a name an enabled plugin already stages (the next sync would delete
# it) and an existing authored skill (unless --update). Never enables, installs,
# or commits.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/scripts}"
SCRIPTS="${SCRIPTS:-${HERE}}"
ADAPTER="${SCRIPTS}/toolsmith.sh"

usage() {
	cat <<'EOF'
usage: vendor-skill.sh <owner/repo@skill> [--name <local-name>] [--root <dir>]
       vendor-skill.sh <github tree url>
       vendor-skill.sh --update <local-name>
       vendor-skill.sh --list

Copies a public GitHub skill into this project's skills directory and records
its source in the layout's vendoring record. Both paths come from
toolsmith.sh --explain, so the same command works in any layout.
EOF
}

die() {
	echo "vendor-skill: $1" >&2
	exit "${2:-1}"
}

require() {
	command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# ── argument parsing ─────────────────────────────────────────────────────────

SOURCE=""
LOCAL_NAME=""
MODE="add"
ROOT="${PWD}"

while [ $# -gt 0 ]; do
	case "$1" in
	--name)
		LOCAL_NAME="${2:-}"
		shift 2
		;;
	--root)
		ROOT="${2:-}"
		shift 2
		;;
	--update)
		MODE="update"
		LOCAL_NAME="${2:-}"
		shift 2
		;;
	--list)
		MODE="list"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--*) die "unknown flag: $1" 2 ;;
	*)
		SOURCE="$1"
		shift
		;;
	esac
done

require jq

# ── the layout ───────────────────────────────────────────────────────────────

EXPLAIN="$(bash "${ADAPTER}" --explain --root "${ROOT}" 2>&1)" ||
	die "$(printf '%s' "${EXPLAIN}" | head -3)" 2

layout_value() {
	printf '%s' "${EXPLAIN}" | jq -r --arg k "$1" '.values[$k] // empty | strings'
}

PROJECT_ROOT="$(layout_value root)"
LAYOUT="$(layout_value layout)"
SYNC_CMD="$(layout_value sync_cmd)"
STAGED_REGISTRY="$(layout_value staged_registry)"

# The two overrides exist so a test can vendor from a local fixture repo, and
# into a fixture tree, without a network call or a real project.
REGISTRY="${VENDOR_SKILL_REGISTRY:-$(layout_value vendor_registry)}"
SKILLS_DIR="${VENDOR_SKILL_SKILLS_DIR:-$(layout_value skills_dir)}"
GIT_BASE="${VENDOR_SKILL_GIT_BASE:-https://github.com/}"
WORK_ROOT="tmp/vendor-skill"

[ -n "${REGISTRY}" ] || die "the ${LAYOUT} layout defines no vendoring record file" 2
cd "${PROJECT_ROOT}" || die "cannot enter ${PROJECT_ROOT}"

if [ "${MODE}" = "list" ]; then
	if [ ! -f "${REGISTRY}" ]; then
		echo "no vendored skills yet"
		exit 0
	fi
	jq -r '.skills | to_entries[] | "\(.key)\t\(.value.source)@\(.value.commit[0:8])\t\(.value.fetchedAt)"' "${REGISTRY}"
	exit 0
fi

if [ "${MODE}" = "add" ] && [ -z "${SOURCE}" ]; then
	usage
	exit 0
fi

require git

# ── resolve source → repo + skill path ───────────────────────────────────────

REPO=""
SKILL_PATH=""
SKILL_NAME=""
REF="HEAD"

if [ "${MODE}" = "update" ]; then
	[ -n "${LOCAL_NAME}" ] || die "--update needs a skill name" 2
	[ -f "${REGISTRY}" ] || die "no record file at ${REGISTRY}" 2
	REPO="$(jq -r --arg n "${LOCAL_NAME}" '.skills[$n].source // empty' "${REGISTRY}")"
	SKILL_PATH="$(jq -r --arg n "${LOCAL_NAME}" '.skills[$n].path // empty' "${REGISTRY}")"
	[ -n "${REPO}" ] || die "\"${LOCAL_NAME}\" is not in ${REGISTRY} — vendor it first" 2
elif [ "${SOURCE#https://github.com/}" != "${SOURCE}" ]; then
	trimmed="${SOURCE#https://github.com/}"
	REPO="$(echo "${trimmed}" | cut -d/ -f1-2)"
	rest="$(echo "${trimmed}" | cut -s -d/ -f3-)"
	[ "${rest#tree/}" != "${rest}" ] || die "a GitHub URL must be a /tree/<ref>/<path> link" 2
	rest="${rest#tree/}"
	REF="$(echo "${rest}" | cut -d/ -f1)"
	SKILL_PATH="$(echo "${rest}" | cut -s -d/ -f2-)"
	[ -n "${SKILL_PATH}" ] || die "the URL must point at the skill directory, not the repo root" 2
elif [ "${SOURCE#*@}" != "${SOURCE}" ]; then
	REPO="${SOURCE%@*}"
	SKILL_NAME="${SOURCE##*@}"
	SKILL_PATH=""
else
	die "source must be <owner/repo@skill> or a github /tree/ URL" 2
fi

[ -n "${LOCAL_NAME}" ] || LOCAL_NAME="$(basename "${SKILL_PATH:-${SKILL_NAME}}")"
[ -n "${LOCAL_NAME}" ] || die "could not derive a local name — pass --name" 2

case "${LOCAL_NAME}" in
*[!a-z0-9-]*) die "local name must be kebab-case: \"${LOCAL_NAME}\"" 2 ;;
esac

DEST="${SKILLS_DIR}/${LOCAL_NAME}"

# ── refusals ─────────────────────────────────────────────────────────────────

# Only a layout that generates its agent dirs can stage plugin content into the
# sources; where there is no such record there is nothing to collide with.
if [ -n "${STAGED_REGISTRY}" ] && [ -f "${STAGED_REGISTRY}" ]; then
	if jq -e --arg p "${DEST}" '(.staged // []) | index($p)' "${STAGED_REGISTRY}" >/dev/null 2>&1; then
		die "\"${LOCAL_NAME}\" is staged by an enabled plugin — the next sync would delete it. Pick another --name." 2
	fi
fi

if [ -d "${DEST}" ] && [ "${MODE}" != "update" ]; then
	die "${DEST} already exists — pass --update ${LOCAL_NAME} to refresh it, or --name for a different name" 2
fi

# ── fetch ────────────────────────────────────────────────────────────────────

CLONE_DIR="${WORK_ROOT}/$(echo "${REPO}" | tr '/' '-')"
mkdir -p "${WORK_ROOT}"
case "${CLONE_DIR}" in
tmp/vendor-skill/*) ;;
*) die "refusing to touch ${CLONE_DIR}" ;;
esac
rm -rf "${CLONE_DIR:?}"

echo "vendor-skill: cloning ${REPO} (${REF})…"
if ! git clone --depth 1 --quiet "${GIT_BASE}${REPO}.git" "${CLONE_DIR}" 2>/dev/null; then
	die "clone failed — is ${GIT_BASE}${REPO} reachable and public?"
fi
if [ "${REF}" != "HEAD" ]; then
	git -C "${CLONE_DIR}" fetch --depth 1 --quiet origin "${REF}" 2>/dev/null &&
		git -C "${CLONE_DIR}" checkout --quiet FETCH_HEAD 2>/dev/null ||
		echo "vendor-skill: ref \"${REF}\" not fetchable, staying on the default branch" >&2
fi
COMMIT="$(git -C "${CLONE_DIR}" rev-parse HEAD)"

# ── locate the skill directory ───────────────────────────────────────────────

if [ -z "${SKILL_PATH}" ]; then
	SKILL_PATH="$(cd "${CLONE_DIR}" && find . -type d -name "${SKILL_NAME}" -exec test -f '{}/SKILL.md' ';' -print 2>/dev/null | head -1)"
	SKILL_PATH="${SKILL_PATH#./}"
	[ -n "${SKILL_PATH}" ] || die "no directory named \"${SKILL_NAME}\" containing SKILL.md in ${REPO}"
fi

SRC="${CLONE_DIR}/${SKILL_PATH}"
[ -f "${SRC}/SKILL.md" ] || die "${REPO}/${SKILL_PATH} has no SKILL.md"

# ── copy ─────────────────────────────────────────────────────────────────────

mkdir -p "${DEST}"
(cd "${SRC}" && tar cf - .) | (cd "${DEST}" && tar xf -) || die "copy failed"

LICENSE_FILE=""
for license in LICENSE LICENSE.md LICENSE.txt; do
	if [ -f "${CLONE_DIR}/${license}" ] && [ ! -f "${DEST}/${license}" ]; then
		cp "${CLONE_DIR}/${license}" "${DEST}/${license}"
		LICENSE_FILE="${license}"
		break
	fi
done

# A generated-config layout needs a targets block on every source file; upstream
# skills rarely carry one. The other layouts read the file as it is, so adding
# a field they do not use would be noise in the diff.
if [ "${LAYOUT}" = "rulesync" ] && ! grep -q '^targets:' "${DEST}/SKILL.md"; then
	awk 'NR==1 && $0=="---" {print; print "targets:"; print "  - '"'"'*'"'"'"; next} {print}' \
		"${DEST}/SKILL.md" >"${DEST}/SKILL.md.tmp" && mv "${DEST}/SKILL.md.tmp" "${DEST}/SKILL.md"
fi

# ── the record ───────────────────────────────────────────────────────────────

FETCHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "${REGISTRY}")"
if [ ! -f "${REGISTRY}" ]; then
	cat >"${REGISTRY}" <<'EOF'
{
  "_comment": "Skills copied from public repos that ship no plugin. Written by vendor-skill.sh; refresh one with --update <name>. Unlike installed plugin content these ARE committed, so keep the upstream source recorded here.",
  "skills": {}
}
EOF
fi

jq --arg n "${LOCAL_NAME}" \
	--arg source "${REPO}" \
	--arg path "${SKILL_PATH}" \
	--arg commit "${COMMIT}" \
	--arg fetched "${FETCHED_AT}" \
	--arg license "${LICENSE_FILE}" \
	'.skills[$n] = {source: $source, path: $path, commit: $commit, fetchedAt: $fetched, license: (if $license == "" then null else $license end), url: ("https://github.com/" + $source + "/tree/" + $commit + "/" + $path)}' \
	"${REGISTRY}" >"${REGISTRY}.tmp" && mv "${REGISTRY}.tmp" "${REGISTRY}"

# ── lint + report ────────────────────────────────────────────────────────────

echo "vendor-skill: vendored ${REPO}/${SKILL_PATH} → ${DEST} (commit ${COMMIT:0:8})"
[ -n "${LICENSE_FILE}" ] && echo "vendor-skill: copied ${LICENSE_FILE}"
echo ""
bash "${SCRIPTS}/validate-dev-tool.sh" "${DEST}/SKILL.md"
echo ""
if [ -n "${SYNC_CMD}" ]; then
	echo "next: review the lint output above, then run \`${SYNC_CMD}\` to fan it out."
else
	echo "next: review the lint output above. This layout has no sync step — the copy is live where it landed."
fi
exit 0
