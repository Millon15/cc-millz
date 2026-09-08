#!/bin/bash
#
# session-start-unslop.sh - unslop-kit SessionStart hook
#
# Injects the unslop-kit directive into the first system-reminder block so
# Claude loads ALL THREE dolls before its first reply:
# `unslop-kit:unslop-formatting` (layout), `unslop-kit:unslop` (wording) and
# `review:writing-style` (precision). Fires on every SessionStart source
# (startup, resume, clear, compact): compaction drops loaded skills, so the
# directive has to come back with it.
#
# Why every name: a directive that names only the wrapper gets the wrapper
# loaded and the inner skills skipped (observed 2026-08-19, the reply was
# written against the abridged fallback while pstack was installed).
#
# Why unslop-kit:unslop and not pstack:unslop: upstream flagged pstack's copy
# `disable-model-invocation` (cursor/plugins PR #300, 2026-09-01), which hides
# it from the model's skill list and makes the Skill tool refuse it. The kit
# ships its own copy, refreshed by scripts/sync-unslop.sh.
#
# stdin:  SessionStart payload (JSON), drained and ignored.
# stdout: { "hookSpecificOutput": { "hookEventName": "SessionStart",
#                                   "additionalContext": "<directive>" } }
# env:    OPT-IN. Mode = $UNSLOP_HOOK if set, else the first line of
#         ~/.claude/unslop-kit.mode (CLAUDE_CONFIG_DIR-aware), else 0.
#         0/absent = silent (the default: installing the plugin must never
#         pollute a session uninvited). 1 = fire in interactive sessions only —
#         headless/SDK runs (CLAUDE_CODE_ENTRYPOINT sdk-*, verified 2026-08-20
#         against `claude -p`) stay silent, the contract formats human-facing
#         text, not agent plumbing. force = fire everywhere (the README's A/B
#         test). The marker file is the durable per-user opt-in: a settings.json
#         {"env":{...}} block does NOT reach hook processes, and declaring
#         UNSLOP_HOOK there even strips an inherited shell export from the hook
#         env (observed 2026-08-20 on 2.1.235). CLAUDE_CONFIG_DIR overrides
#         ~/.claude for the install checks and the marker.
# exit:   0 always. A hook must never block session start.
# deps:   jq
#
# Portability: `read -r -d ''` instead of `$(cat <<'EOF' … )` because bash 3.2
# (macOS) mis-parses an apostrophe inside a heredoc nested in $( ).
#
set -euo pipefail

cat >/dev/null || true

mode="${UNSLOP_HOOK:-}"
mode_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/unslop-kit.mode"
if [ -z "$mode" ] && [ -r "$mode_file" ]; then
	IFS= read -r mode <"$mode_file" || true
fi
case "$mode" in
force) ;;
1) case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk*) exit 0 ;; esac ;;
*) exit 0 ;;
esac

installed_json="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"

plugin_installed() {
	[ -r "$installed_json" ] &&
		jq -e --arg p "$1" '(.plugins[$p] // []) | length > 0' "$installed_json" >/dev/null 2>&1
}

pass1_call='Skill(skill="unslop-kit:unslop") - pass 1, the wording'
IFS= read -r -d '' pass1 <<'EOF' || true
`unslop-kit:unslop` ships with this kit, so the pass-1 call is never optional:
`Skill(skill="unslop-kit:unslop")` in the SAME tool batch as the others. It is the
31-pattern pstack unslop body kept model-invocable; `pstack:unslop` itself is
user-invocation-only and the Skill tool refuses it. A reply written without a
visible `Skill(skill="unslop-kit:unslop")` call in this context window did not
get pass 1.
EOF

if plugin_installed "review@umputun-cc-thingz"; then
	pass2_call='Skill(skill="review:writing-style") - pass 2, the precision'
	IFS= read -r -d '' pass2 <<'EOF' || true
review@umputun-cc-thingz is installed too, so the pass-2 call is equally
mandatory: `Skill(skill="review:writing-style")` in the same batch. Its User
Override Check does not fire here; unslop-formatting names which of its
sections apply.
EOF
else
	pass2_call='(skip) Skill(skill="review:writing-style") is not available here, see below'
	IFS= read -r -d '' pass2 <<'EOF' || true
review@umputun-cc-thingz is NOT installed on this machine, so pass 2 runs on the
precision checklist inside unslop-formatting. Say so once, in your first reply.
EOF
fi

IFS= read -r -d '' directive <<EOF || true
<EXTREMELY-IMPORTANT>
unslop-kit is ON for this session. Before your first reply, and again after any
compaction (loaded skills do not survive it), make THREE Skill calls in ONE batch:

1. Skill(skill="unslop-kit:unslop-formatting") - pass 3, the layout
2. $pass1_call
3. $pass2_call

$pass1
$pass2
It is a Russian doll: pass 1 \`unslop-kit:unslop\` cuts the AI tells from the wording,
pass 2 \`review:writing-style\` pins every claim to an exact reference
(path:line, PR #n, commit, link) and a flat verdict, pass 3 \`unslop-formatting\`
lays the reply out as figure-paragraphs (English Check block first and
untouched, TL;DR, then per paragraph: one emoji bold claim line, at most two
prose sentences, at most one small numeric table, at least one italic caption
ABOVE a hand-drawn ASCII visual (branch rail, state rail, sequence rail, box
map, bar or edge list; never mermaid source, the TUI shows it as text), a 2-7
line blockquote receipt ledger, and a --- separator; NO nested lists,
everything block-level at column zero, EVERY line hard-wrapped at 120 columns,
prose broken mid-sentence onto the next line when it must be).

Every prose surface you produce takes passes 1 and 2 BEFORE it leaves you: chat
replies, commit messages, PR titles and descriptions, code comments and
docblocks, docs, Slack/Jira/Linear bodies, handoffs, plans. Chat replies also
take pass 3. Then the send-check in the skill.
</EXTREMELY-IMPORTANT>
EOF

jq -nc --arg ctx "$directive" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
