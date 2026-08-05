---
description: Forensic search of past Claude Code sessions from a natural-language description — full IDs, models, timelines.
disable-model-invocation: true
---

Find the past session(s) matching the description in `$ARGUMENTS` and report them in the contract
below. Sessions have no stored titles — a session's "name" is its first user prompt.

## Data sources

- `~/.claude/projects/<flattened-cwd>/*.jsonl` — one transcript per session; `<flattened-cwd>` =
  absolute project path with `/` → `-`. Search other projects' dirs only when asked.
- `~/.claude/history.jsonl` — every prompt the user typed: `{display, timestamp_ms, project,
  sessionId}`. The fastest index of what the USER said, and where session names come from.
- `~/.claude/sessions/*.json` — live/background registry; may carry a human `name` for
  still-registered sessions.

## Procedure

1. **Parse the ask** into search keys and a date window. Loosen every key: `FP-227` →
   `grep -iE 'FP-?227'` — branch names lowercase keys and hyphens drop. Convert relative dates
   ("вчера", "last 3 days") to absolute `YYYY-MM-DD` before grepping.
2. **Collect candidates**: `grep -l` the keys over `*.jsonl`, keep files that also hit
   `"timestamp":"<date>` for a date inside the window. Trust in-file timestamps, never file
   mtime — a resumed session touches the file without adding entries.
3. **Split dialogs from workers.** Count key hits inside user-authored messages:
   `jq -r 'select(.message.role=="user" and (.isMeta!=true) and (.message.content|type=="string")) | .message.content'`.
   Zero user hits plus a first message like "Read the plan file…", "Code review of:", "Review this
   change for security vulnerabilities" = headless worker (ralphex / review lane / `claude -p`),
   not the user's dialog.
4. **Profile each survivor**: name (first prompt from `history.jsonl`, else first user message in
   the transcript), models (`grep -o '"model":"claude-[a-z0-9.-]*"' | sort | uniq -c`), activity
   window inside the requested dates, total key-mention count. Done when every candidate is either
   profiled or classified as a worker.

## Report contract

- TL;DR first: which session is THE one, in one sentence.
- Interactive-sessions table: full session ID in backticks | «name» (first prompt, ≤100 chars) |
  models with message counts | activity window (date + HH:MM UTC) | key mentions.
- **Full UUIDs, always.** A truncated ID cannot be resumed and forces a follow-up question.
- Headless workers: separate fenced block of full IDs plus one line on what they were.
- Close with the ready-to-paste resume line for the top hit — `claude --resume <full-id>` — and
  the transcript path.
- Matches outside the requested window get one honest line, not a table row.
- Shell notes: `/bin/ls` (plain `ls` may be aliased to eza), `jq` for JSON — never inline python.
