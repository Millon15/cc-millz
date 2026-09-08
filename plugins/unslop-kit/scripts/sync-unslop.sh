#!/bin/bash
#
# sync-unslop.sh - refresh the vendored unslop-kit:unslop skill from pstack
#
# Upstream cursor/plugins flagged pstack's unslop `disable-model-invocation`
# (PR #300, 2026-09-01), which removes it from the model's skill list and makes
# the Skill tool refuse it. unslop-kit needs the same 31 patterns reachable by
# the model and by other skills, so it ships its own copy: the upstream body
# verbatim under a model-facing frontmatter, plus one provenance line.
#
# usage:  sync-unslop.sh [--check] [SOURCE_SKILL_MD]
#         SOURCE_SKILL_MD defaults to the installed pstack@cc-millz copy,
#         resolved from installed_plugins.json (CLAUDE_CONFIG_DIR-aware).
#         --check compares instead of writing.
# exit:   0 written or in sync · 1 --check found drift · 2 no source found
# deps:   jq, awk
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${script_dir}/../skills/unslop/SKILL.md"
installed_json="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"

description='Cut AI tells from any writing with the 31 numbered patterns and the self-audit. Use before any prose leaves you (chat reply, commit message, PR body, code comment, doc, Slack/Jira/Linear body), on "unslop", "de-AI this", "make it sound human", or when another skill (unslop-kit:unslop-formatting, a project outbound skill) needs pass 1. Verbatim body of pstack unslop (MIT, Lauren Tan), kept model-invocable; refresh with scripts/sync-unslop.sh.'

usage_error() {
	printf 'sync-unslop.sh: %s\n' "$1" >&2
	exit 2
}

pstack_install_path() {
	[ -r "$installed_json" ] || return 1
	jq -er '.plugins["pstack@cc-millz"][0].installPath // empty' "$installed_json" 2>/dev/null
}

pstack_commit_sha() {
	[ -r "$installed_json" ] || {
		printf 'unknown'
		return
	}
	jq -r '.plugins["pstack@cc-millz"][0].gitCommitSha // "unknown"' "$installed_json" 2>/dev/null | cut -c1-12
}

resolve_source() {
	if [ -n "${1:-}" ]; then
		printf '%s' "$1"
		return
	fi
	local root
	root="$(pstack_install_path)" || usage_error "pstack@cc-millz is not in ${installed_json}; pass the SKILL.md path explicitly"
	printf '%s/skills/unslop/SKILL.md' "$root"
}

upstream_body() {
	awk 'BEGIN { fences = 0 } /^---$/ && fences < 2 { fences++; next } fences == 2 { print }' "$1"
}

render() {
	local source="$1" sha="$2" date="$3"
	printf -- '---\nname: unslop\ndescription: %s\n---\n' "$description"
	printf '<!-- vendored from cursor/plugins pstack/skills/unslop/SKILL.md @ %s on %s by scripts/sync-unslop.sh; edit upstream, then re-sync -->\n' "$sha" "$date"
	upstream_body "$source"
}

drifted() {
	local rendered="$1"
	[ -r "$target" ] || return 0
	! diff -q <(sed '/^<!-- vendored from/d' "$target") <(printf '%s\n' "$rendered" | sed '/^<!-- vendored from/d') >/dev/null
}

main() {
	local check=0
	[ "${1:-}" = "--check" ] && {
		check=1
		shift
	}
	local source rendered
	source="$(resolve_source "${1:-}")"
	[ -r "$source" ] || usage_error "no readable SKILL.md at ${source}"
	rendered="$(render "$source" "$(pstack_commit_sha)" "$(date +%Y-%m-%d)")"
	if [ "$check" -eq 1 ]; then
		drifted "$rendered" && {
			printf 'sync-unslop.sh: %s is behind %s\n' "$target" "$source" >&2
			exit 1
		}
		printf 'sync-unslop.sh: in sync with %s\n' "$source"
		return
	fi
	mkdir -p "$(dirname "$target")"
	printf '%s\n' "$rendered" >"$target"
	printf 'sync-unslop.sh: wrote %s from %s\n' "$target" "$source"
}

main "$@"
