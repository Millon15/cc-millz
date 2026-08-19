#!/bin/bash
#
# session-start-unslop.sh - unslop-kit SessionStart hook
#
# Injects the unslop-kit directive into the first system-reminder block so
# Claude loads BOTH dolls before its first reply: `unslop-kit:unslop-formatting`
# (layout) and `pstack:unslop` (wording). Fires on every SessionStart source
# (startup, resume, clear, compact): compaction drops loaded skills, so the
# directive has to come back with it.
#
# Why both names: a directive that names only the wrapper gets the wrapper
# loaded and the inner `pstack:unslop` skipped (observed 2026-08-19, the reply
# was written against the abridged fallback while pstack was installed).
#
# stdin:  SessionStart payload (JSON), drained and ignored.
# stdout: { "hookSpecificOutput": { "hookEventName": "SessionStart",
#                                   "additionalContext": "<directive>" } }
# env:    UNSLOP_HOOK=0 opts one session out (A/B runs, headless jobs).
#         CLAUDE_CONFIG_DIR overrides ~/.claude for the pstack install check.
# exit:   0 always. A hook must never block session start.
# deps:   jq
#
# Portability: `read -r -d ''` instead of `$(cat <<'EOF' … )` because bash 3.2
# (macOS) mis-parses an apostrophe inside a heredoc nested in $( ).
#
set -euo pipefail

cat >/dev/null || true

[ "${UNSLOP_HOOK:-1}" != "0" ] || exit 0

installed_json="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
pstack_installed=0
if [ -r "$installed_json" ] \
  && jq -e '(.plugins["pstack@cc-millz"] // []) | length > 0' "$installed_json" >/dev/null 2>&1; then
  pstack_installed=1
fi

if [ "$pstack_installed" = 1 ]; then
  pass1_call='Skill(skill="pstack:unslop") - pass 1, the wording'
  IFS= read -r -d '' pass1 <<'EOF' || true
pstack@cc-millz is installed on this machine, so the SECOND call is not optional:
`Skill(skill="pstack:unslop")` in the SAME tool batch as the first. The abridged
fallback checklist inside unslop-formatting is for machines where `pstack:unslop`
is absent from the skill list; here it is a violation. A reply written without a
visible `Skill(skill="pstack:unslop")` call in this context window did not get
pass 1.
EOF
else
  pass1_call='(skip) Skill(skill="pstack:unslop") is not available here, see below'
  IFS= read -r -d '' pass1 <<'EOF' || true
pstack@cc-millz is NOT installed on this machine, so pass 1 runs on the abridged
fallback checklist inside unslop-formatting. Say so once, in your first reply.
Install with `/plugin install pstack@cc-millz` to get the full 31-pattern pass.
EOF
fi

IFS= read -r -d '' directive <<EOF || true
<EXTREMELY-IMPORTANT>
unslop-kit is ON for this session. Before your first reply, and again after any
compaction (loaded skills do not survive it), make TWO Skill calls in ONE batch:

1. Skill(skill="unslop-kit:unslop-formatting") - pass 2, the layout
2. $pass1_call

$pass1
It is a Russian doll: pass 1 \`pstack:unslop\` cuts the AI tells from the wording,
pass 2 \`unslop-formatting\` lays the reply out (English Check block first and
untouched, TL;DR, nested bullets with one emoji glyph per top-level item, tables
for comparisons, fenced code with language tags, tables and code blocks only at
column zero).

Every prose surface you produce takes pass 1 BEFORE it leaves you: chat replies,
commit messages, PR titles and descriptions, code comments and docblocks, docs,
Slack/Jira/Linear bodies, handoffs, plans. Chat replies also take pass 2. Then
the send-check in the skill.
</EXTREMELY-IMPORTANT>
EOF

jq -nc --arg ctx "$directive" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
