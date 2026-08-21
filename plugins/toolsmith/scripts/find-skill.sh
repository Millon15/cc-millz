#!/usr/bin/env bash
#
# find-skill.sh — rank what already exists before authoring a new dev tool.
#
#   find-skill.sh <query...> [--root <dir>] [--remote] [--tier a,b] [--limit N] [--json]
#   find-skill.sh --exact <name> [--remote]
#
# A thin wrapper over find-skill.ts so a permission allowlist has one stable
# entry and no caller has to know the runtime. The search itself asks
# toolsmith.sh which layout this project has, so nothing here names a directory.
#
# Exit codes: 0 on a completed search (no hits is a result, not a failure);
# 2 on bad usage; 1 when bun is missing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/scripts}"
SCRIPTS="${SCRIPTS:-${HERE}}"

if [ "$#" -eq 0 ]; then
	echo "usage: find-skill.sh <query...> [--root <dir>] [--remote] [--tier a,b] [--limit N] [--json]"
	echo "       find-skill.sh --exact <name> [--remote]"
	exit 0
fi

if ! command -v bun >/dev/null 2>&1; then
	echo "find-skill: bun is not installed — see https://bun.sh" >&2
	exit 1
fi

exec bun "${SCRIPTS}/find-skill.ts" "$@"
