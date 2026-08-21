#!/usr/bin/env bash
#
# validate-dev-tool.sh — non-blocking linter for agent dev-tool layers.
#
# Invoked by /toolsmith:create after authoring each layer, by /toolsmith:check
# in its audit mode, and by vendor-skill.sh over what it just copied in.
#
# Input (two modes):
#   1. a target file-path arg:  validate-dev-tool.sh path/to/rule.md
#   2. stdin JSON:              echo '{"tool_input":{"file_path":"..."}}' | validate-dev-tool.sh
#
# WHICH directory holds which layer comes from toolsmith.sh, never from a
# literal here: the same lint runs over a generated-config project, a plugin
# repo and a plain checkout. A file under one of the layout's GENERATED dirs
# still lints, and gets a loud "edit the source instead" warning on top. Any
# path outside every known layer directory is a no-op (exit 0).
#
# Output is a single JSON object:
#   {"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"..."}}
#
# NEVER blocks — always exits 0. Warnings live in additionalContext.
#
# Checks: (a) frontmatter line 1 == --- (all md layers); (b) dangling skill
# references; (c) per-layer line caps (warn, frontmatter excluded); (d) $(
# command substitution; (e) absolute /Users/ or /home/ paths; (f) ## Related
# Documentation footer forbidden in agent-context files; (g) skill description
# present — the only discovery surface a skill has; (h) generated-path warning.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/scripts}"
SCRIPTS="${SCRIPTS:-${HERE}}"
ADAPTER="${SCRIPTS}/toolsmith.sh"

emit() { # $1 = additionalContext message; always exits 0
	jq -n --arg msg "$1" '{
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": $msg
        }
    }'
	exit 0
}

# ── the layout ───────────────────────────────────────────────────────────────

# Resolves the layout from a directory inside the project. A directory with no
# marker leaves EXPLAIN empty, and every layer test then falls through to the
# no-op exit — a linter is not the place to fail a project for its shape.
EXPLAIN=""
load_layout() {
	EXPLAIN="$(bash "${ADAPTER}" --explain --root "$1" 2>/dev/null || true)"
}

layout_value() { # $1 = key; prints the value, or nothing when absent or null
	[ -n "${EXPLAIN}" ] || return 0
	printf '%s' "${EXPLAIN}" | jq -r --arg k "$1" '.values[$k] // empty | strings'
}

layout_list() { # $1 = key of an array value; prints one element per line
	[ -n "${EXPLAIN}" ] || return 0
	printf '%s' "${EXPLAIN}" | jq -r --arg k "$1" '.values[$k] // [] | .[]'
}

# ── mode dispatch: --audit (lint + conformance framing) / --retire (dry-run) ─
MODE="lint"
case "${1:-}" in
--retire)
	# Dry-run lister ONLY — NEVER deletes. Deletion is the command's job after
	# the user confirms. Args: --retire <tool> [root]
	TOOL="${2:-}"
	ROOT="${3:-${PWD}}"
	if [ -z "${TOOL}" ]; then
		echo "usage: validate-dev-tool.sh --retire <tool> [root]"
		exit 0
	fi
	load_layout "${ROOT}"
	if [ -z "${EXPLAIN}" ]; then
		echo "RETIRE: no agent-config layout at ${ROOT} — nothing to list."
		exit 0
	fi
	BASE="$(layout_value root)"
	SKILLS="$(layout_value skills_dir)"
	COMMANDS="$(layout_value commands_dir)"
	AGENTS="$(layout_value agents_dir)"
	RULES="$(layout_value rules_dir)"
	FOUND=()
	while IFS= read -r f; do
		[ -n "${f}" ] && FOUND+=("${f}")
	done < <(find "${BASE}/${COMMANDS}" -name "${TOOL}.md" 2>/dev/null)
	[ -d "${BASE}/${SKILLS}/${TOOL}" ] && FOUND+=("${BASE}/${SKILLS}/${TOOL}/")
	[ -n "${AGENTS}" ] && [ -e "${BASE}/${AGENTS}/${TOOL}.md" ] && FOUND+=("${BASE}/${AGENTS}/${TOOL}.md")
	[ -n "${RULES}" ] && [ -e "${BASE}/${RULES}/${TOOL}.md" ] && FOUND+=("${BASE}/${RULES}/${TOOL}.md")
	echo "RETIRE (dry-run — NO deletion performed; the command deletes after confirmation):"
	if [ ${#FOUND[@]} -eq 0 ]; then
		echo "  (no source file under ${SKILLS}, ${COMMANDS}, ${AGENTS:-none} or ${RULES:-none} matches tool '${TOOL}')"
	else
		for f in "${FOUND[@]}"; do echo "  would delete: ${f}"; done
	fi
	GEN="$(layout_list generated_dirs | tr '\n' ' ')"
	if [ -n "${GEN% }" ]; then
		SYNC="$(layout_value sync_cmd)"
		echo "  generated outputs (${GEN% }) are rewritten by ${SYNC:-the project sync step} — never hand-deleted"
	fi
	exit 0
	;;
--audit)
	MODE="audit"
	shift
	;;
esac

# ── resolve target file path: positional arg first, else stdin JSON ──────────
FILE_PATH=""
if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
	FILE_PATH="$1"
else
	INPUT="$(cat)"
	FILE_PATH="$(printf '%s' "${INPUT}" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
fi

[ -z "${FILE_PATH}" ] && exit 0
[ ! -f "${FILE_PATH}" ] && exit 0

load_layout "$(dirname "${FILE_PATH}")"
[ -n "${EXPLAIN}" ] || exit 0

BASE="$(layout_value root)"
SKILLS_DIR="$(layout_value skills_dir)"
COMMANDS_DIR="$(layout_value commands_dir)"
AGENTS_DIR="$(layout_value agents_dir)"
RULES_DIR="$(layout_value rules_dir)"
SYNC_CMD="$(layout_value sync_cmd)"

ABS="$(cd "$(dirname "${FILE_PATH}")" && pwd -P)/$(basename "${FILE_PATH}")"
REL="${ABS#"${BASE}"/}"

# ── layer detection over the layout's own directories ───────────────────────
# Source dirs first, then the generated mirrors: a generated tree carries the
# same four layer names under each of the dirs the sync writes.
LAYER=""
GENERATED=""

layer_under() { # $1 = skills dir, $2 = commands, $3 = agents, $4 = rules
	case "${REL}" in
	"$1"/*.tmpl) printf 'tmpl\n' ;;
	"$1"/*/SKILL.md | "$1"/SKILL.md) printf 'skill\n' ;;
	"$1"/*.md) printf 'skill-aux\n' ;;
	esac
	case "${REL}" in "$2"/*.md) printf 'command\n' ;; esac
	[ -n "$3" ] && case "${REL}" in "$3"/*.md) printf 'agent\n' ;; esac
	[ -n "$4" ] && case "${REL}" in "$4"/*.md) printf 'rule\n' ;; esac
	return 0
}

LAYER="$(layer_under "${SKILLS_DIR}" "${COMMANDS_DIR}" "${AGENTS_DIR}" "${RULES_DIR}" | head -1)"

if [ -z "${LAYER}" ]; then
	while IFS= read -r gen; do
		[ -n "${gen}" ] || continue
		LAYER="$(layer_under "${gen}/skills" "${gen}/commands" "${gen}/agents" "${gen}/rules" | head -1)"
		if [ -n "${LAYER}" ]; then
			GENERATED="yes"
			break
		fi
	done < <(layout_list generated_dirs)
fi

[ -z "${LAYER}" ] && exit 0

BASENAME="$(basename "${FILE_PATH}")"
LINE1="$(head -1 "${FILE_PATH}")"
NLINES="$(wc -l <"${FILE_PATH}" | tr -d ' ')"

# body lines = total minus the YAML frontmatter block
BODY_LINES="${NLINES}"
if [ "${LINE1}" = "---" ]; then
	FM_END="$(tail -n +2 "${FILE_PATH}" | grep -nm1 '^---$' | cut -d: -f1)"
	[ -n "${FM_END}" ] && BODY_LINES=$((NLINES - FM_END - 1))
fi

WARN=""
add() { WARN="${WARN}${WARN:+$'\n'}• $1"; }

if [ -n "${GENERATED}" ]; then
	add "GENERATED PATH: ${FILE_PATH} is a generated file — edit the source under ${SKILLS_DIR%/skills}/ instead; ${SYNC_CMD:-the project sync step} overwrites this copy"
fi

# helper: does this tmpl scaffold target a frontmatter-bearing md layer?
tmpl_has_frontmatter() {
	case "${BASENAME}" in
	SKILL.md.tmpl | command.md.tmpl | agent.md.tmpl) return 0 ;;
	*) return 1 ;;
	esac
}
# helper: is a ## Related Documentation footer forbidden here? (human docs only)
footer_forbidden() {
	case "${LAYER}" in
	rule | skill | command | agent) return 0 ;;
	tmpl)
		[ "${BASENAME}" != script.sh.tmpl ] && return 0
		return 1
		;;
	*) return 1 ;;
	esac
}

# ── (a) frontmatter line 1 == --- ───────────────────────────────────────────
case "${LAYER}" in
rule | skill | command | agent)
	[ "${LINE1}" != "---" ] && add "FRONTMATTER BROKEN: line 1 is '${LINE1:0:40}', expected --- (every md layer opens with a YAML frontmatter block)"
	;;
tmpl)
	if tmpl_has_frontmatter && [ "${LINE1}" != "---" ]; then
		add "FRONTMATTER BROKEN: line 1 is '${LINE1:0:40}', expected ---"
	fi
	;;
esac

# ── (b) dangling skill references ────────────────────────────────────────────
# Match "<name> skill" where <name> is kebab-case or namespaced. Namespaced
# (plugin) refs with ':' are assumed valid; bare kebab names must resolve to a
# skill directory this project or this machine actually has.
skill_exists() {
	local name="$1" gen
	[ -f "${BASE}/${SKILLS_DIR}/${name}/SKILL.md" ] && return 0
	[ -f "${HOME}/.claude/skills/${name}/SKILL.md" ] && return 0
	while IFS= read -r gen; do
		[ -n "${gen}" ] || continue
		[ -f "${BASE}/${gen}/skills/${name}/SKILL.md" ] && return 0
	done < <(layout_list generated_dirs)
	return 1
}

while IFS= read -r cand; do
	[ -z "${cand}" ] && continue
	name="${cand% skill}"
	name="${name//\`/}"
	name="${name## }"
	case "${name}" in *[-:]*) ;; *) continue ;; esac # require hyphen or colon
	case "${name}" in *:*) continue ;; esac          # namespaced plugin → valid
	skill_exists "${name}" && continue
	add "DANGLING SKILL REF: \`${name}\` skill — no such skill registered"
done < <(grep -oE '`?[A-Za-z0-9][A-Za-z0-9:_-]+`? skill' "${FILE_PATH}" 2>/dev/null | sort -u)

# ── (c) per-layer line caps (warn, never block) ─────────────────────────────
case "${LAYER}" in
rule) [ "${BODY_LINES}" -gt 50 ] && add "LINE CAP: rule body has ${BODY_LINES} lines (frontmatter excluded), exceeds 50 (warn, not a block — split to a skill?)" ;;
agent) [ "${BODY_LINES}" -gt 120 ] && add "LINE CAP: agent body has ${BODY_LINES} lines, exceeds ~120 (warn)" ;;
skill) [ "${BODY_LINES}" -gt 1000 ] && add "LINE CAP: skill body has ${BODY_LINES} lines, exceeds 1000 (warn)" ;;
esac

# ── (d) $( command substitution (prose layers only; scripts use it legitimately) ─
# A layer that BANS command substitution has to quote it. Flagging the
# prohibition is a false positive that trains authors to delete the rule, so
# exempt a `$(` whose line documents rather than performs it:
#   A. the ellipsis form is the NOTATION for the concept, never a command
#   B. the line negates it (never / not / no / avoid / without / forbid)
substitution_lines() {
	awk '
        index($0, "$(") == 0 { next }
        { probe = $0; gsub(/\$\(\.\.\.\)|\$\(…\)/, "", probe) }
        index(probe, "$(") == 0 { next }
        tolower($0) ~ /never|avoid|forbid|without|(^|[^a-z])not?([^a-z]|$)/ { next }
        { print NR }
    ' "$1"
}

if [[ "${BASENAME}" != *.sh.tmpl ]]; then
	SUBST_LINES="$(substitution_lines "${FILE_PATH}" | tr '\n' ',' | sed 's/,$//')"
	[ -n "${SUBST_LINES}" ] && add "COMMAND SUBSTITUTION: \$( on line(s) ${SUBST_LINES} — use the two-call pattern (no command substitution)"
fi

# ── (e) absolute home paths (concrete segment only — placeholders OK) ───────
if grep -qE '/(Users|home)/[A-Za-z0-9_-]+' "${FILE_PATH}"; then
	add "ABSOLUTE PATH: a concrete home directory is baked in — use a relative path or \${CLAUDE_PLUGIN_ROOT}"
fi

# ── (f) ## Related Documentation footer forbidden in agent-context files ────
# Fenced code blocks are ignored — the heading may legitimately appear inside
# an example of a human-docs file.
if footer_forbidden && awk '/^```/{f=!f;next} !f' "${FILE_PATH}" | grep -q '^## Related Documentation$'; then
	add "FORBIDDEN FOOTER: '## Related Documentation' is a human-docs convention — remove it from agent-context files, which pay per token"
fi

# ── (g) skill discoverability: description must be present ──────────────────
# A skill's frontmatter description is its ONLY discovery surface — a custom
# metadata block is not read by the agent, so trigger phrases belong in the
# description or nowhere.
if [ "${LAYER}" = "skill" ] || { [ "${LAYER}" = "tmpl" ] && [ "${BASENAME}" = "SKILL.md.tmpl" ]; }; then
	grep -qE '^[[:space:]]*description:' "${FILE_PATH}" ||
		add "MISSING DESCRIPTION: no frontmatter description — future sessions will not discover this skill (put its trigger phrases there)"
	grep -qE '^[[:space:]]*triggers:' "${FILE_PATH}" &&
		add "DEAD FIELD: a triggers: block is not a discovery surface — move those phrases into description"
fi

# ── emit verdict (always exit 0) ────────────────────────────────────────────
if [ "${MODE}" = "audit" ]; then
	if [ -z "${WARN}" ]; then
		emit "AUDIT CONFORMANT: ${BASENAME} (${LAYER}) — passes all dev-tool checks"
	else
		emit "AUDIT REPORT for ${BASENAME} (${LAYER}) — non-conformant:"$'\n'"${WARN}"
	fi
elif [ -z "${WARN}" ]; then
	emit "dev-tool lint clean: ${BASENAME} (${LAYER})"
else
	emit "dev-tool lint warnings for ${BASENAME} (${LAYER}):"$'\n'"${WARN}"
fi
