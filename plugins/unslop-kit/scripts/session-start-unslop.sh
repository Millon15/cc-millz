#!/bin/bash
#
# session-start-unslop.sh - unslop-kit SessionStart hook
#
# Injects the unslop-kit directive into the first system-reminder block so
# Claude loads `unslop-kit:unslop-formatting` before its first reply. Fires on every
# SessionStart source (startup, resume, clear, compact): compaction drops the
# loaded skill, so the directive has to come back with it.
#
# stdin:  SessionStart payload (JSON), drained and ignored.
# stdout: { "hookSpecificOutput": { "hookEventName": "SessionStart",
#                                   "additionalContext": "<directive>" } }
# env:    UNSLOP_HOOK=0 opts one session out (A/B runs, headless jobs).
# exit:   0 always. A hook must never block session start.
# deps:   jq
#
# Portability: `read -r -d ''` instead of `$(cat <<'EOF' … )` because bash 3.2
# (macOS) mis-parses an apostrophe inside a heredoc nested in $( ).
#
set -euo pipefail

cat >/dev/null || true

[ "${UNSLOP_HOOK:-1}" != "0" ] || exit 0

IFS= read -r -d '' directive <<'EOF' || true
<EXTREMELY-IMPORTANT>
unslop-kit is ON for this session. Invoke Skill(skill="unslop-kit:unslop-formatting")
NOW, before your first reply, and again after any compaction (a loaded skill
does not survive it). It is a Russian doll: pass 1 `pstack:unslop` cuts the AI
tells from the wording, pass 2 `unslop-formatting` lays the reply out (English Check
block first and untouched, TL;DR, nested bullets with one emoji glyph per
top-level item, tables for comparisons, fenced code with language tags).

Every prose surface you produce takes pass 1 BEFORE it leaves you: chat
replies, commit messages, PR titles and descriptions, code comments and
docblocks, docs, Slack/Jira/Linear bodies, handoffs, plans. Chat replies also
take pass 2. Then the send-check in the skill.
</EXTREMELY-IMPORTANT>
EOF

jq -nc --arg ctx "$directive" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
