# Changelog

## essentials v0.6.0 - 2026-08-05

### New Features

- `/recall` command — forensic search of past Claude Code sessions from a natural-language
  description ("the session where I discussed testing ABC-1162, last 3 days"). Encodes the
  session-archaeology procedure: transcripts in `~/.claude/projects/<flattened-cwd>/*.jsonl`,
  `~/.claude/history.jsonl` as the index of user prompts (and the source of session "names" —
  a session has no stored title, its name is its first prompt), loosened case-insensitive key
  matching, in-file timestamps over mtime, and the dialog-vs-headless-worker split (ralphex /
  review lanes / `claude -p` runs are reported separately, never as the user's conversations).
  Report contract: TL;DR first, table with FULL untruncated session UUIDs + models + activity
  windows, ready-to-paste `claude --resume <full-id>` line. `disable-model-invocation: true` —
  user-invoked only

## essentials v0.5.0 - 2026-08-04

### New Features

- `/tldr` command — re-renders the discussion already in context as `## Conclusions` +
  `## Actionable items`, nothing else. Same form as `/e15` (re-render what is on screen, no new
  work), opposite purpose: `/e15` simplifies the language, `/tldr` removes everything that is not
  a conclusion or a next step. Runs the `concise-writing` fact test, keeps numbers / `file:line` /
  SHAs / flag names and drops the derivation, caps each section at 7 one-line bullets, prefixes
  anything blocked on the user with `**Decide:**`, and emits `- None.` rather than padding
- `disable-model-invocation: true` on `/tldr` — user-invoked only. A model that can call it will
  reach for it as a summariser mid-turn, which is the one place compression loses facts

### Docs

- README: added the missing `essentials:concise-writing` row alongside the new `/tldr` row

### New Features

- `concise-writing` skill — the compression procedure (the "does the reader lose a FACT?"
  test, merge-repeats-upward, and a hard stop condition) as the concision floor for code
  comments, commit bodies, PR descriptions and team-visible sends. Extracted after a review
  found ~27% comment-to-code ratio in a shipped PR pair. `code-style` now delegates comment
  prose to it and adds a <10% prose-comment ceiling

## agterm-lanes v0.1.0 - 2026-07-30

### New Features

- New plugin: every agterm pane running Claude Code labels itself, moved from `~/.claude/hooks/`
- `agterm-lane.sh` — names the lane from Claude's own session title (a bare `/rename` typed into the pane, then the new title read back over OSC), then derives a role emoji, pane tint and sidebar glyph from it. Fires on the first `Stop` **or** the first `AskUserQuestion`/`ExitPlanMode`, whichever comes first: a turn that asks the user something never ends, so a session can otherwise sit unnamed forever on one unanswered question. The question path never injects keystrokes — a dialog is on screen and Return would answer it — and adopts the auto-title instead
- `agterm-status.sh` — agent-status indicator that **replays the lane's glyph on every call**, because `--shape` rides a single status call and reverts on the next one without it. Ships here rather than patching agterm's installer-written `agent-status` script, which an agterm upgrade silently overwrites
- `agterm-pin-resume.sh` — rewrites the pane's `session restore` pin to the live session id on every `SessionStart`, so a reboot reattaches the conversation instead of opening a bare shell. A per-pane pin bypasses `restore-denylist.conf` by design
- Role → style map is a decision table: hue and silhouette encode the **role**, never turn state — state keeps the status palette to itself

## essentials v0.2.0 - 2026-07-30

### New Features

- `/e15` command — re-explain the topic currently under discussion as if to a 15-year-old, simplifying the language without softening the facts. Moved from `~/.claude/commands/`

## phpstorm v0.1.0 - 2026-07-30

### New Features

- New plugin targeting PhpStorm 2026.2+, which exposes ~64 MCP tools including a full Xdebug debugger surface
- `phpstorm-debug` skill — live debugging loop built on the **attach, don't launch** pattern: the IDE's own launcher times out against remote/Docker interpreters, so arm a breakpoint, trigger the code externally in the background, and attach. Carries the three-condition preflight (listening / server-name mapping / force-break off), session hygiene (`sessionId` contention from background crons, `frameIndex` expiry, post-restart breakpoint ownership), and the empirically-confirmed dead ends — logpoint output never drains for Xdebug and `hitCount` is always `0`
- `phpstorm-mcp` skill — tool map for indexed code, leading with `analyze_calls` (resolved call hierarchy) over text search for finding callers; inspections + quick fixes after edits, `paths[]` glob scoping, IDE-backed SQL, and the 2026.2 tool renames (`search_in_files_by_text` → `search_text`, `find_files_by_name_keyword` → `search_file`)

## essentials v0.1.2 - 2026-07-21

### Other

- `code-style`: added Core bullets for canonical class layout (members declared at top, no `const`/property stranded between methods) and reaching for modern language features (PHP 8.0+ constructs over legacy idioms)

## essentials v0.1.1 - 2026-07-14

### Other

- Softened scope guidance: user-scope is the default, team-wide enablement is a deliberate repo-owner decision (plugin.json, README, CLAUDE.md)

## essentials v0.1.0 - 2026-07-14

### New Features

- `code-style` skill — personal code taste (declarative orchestrators, SLAP, flat control flow, typed VOs, fail-fast) moved from `~/.claude/skills/`

## codex-delegation v0.1.0 - 2026-07-14

### New Features

- `codex-delegate` skill — routing brain: intent → openai-codex plugin command/agent, model rubric (gpt-5.6 top tier / gpt-5.5 bulk), preflight, verification stance
- `codex-workflow-fanout` skill — gpt workers inside Workflow/Agent fan-outs (thin wrappers, `gpt-5.6:` labels, worktree isolation)
- `codex-computer-use` skill — independent UI/runtime verification via `codex exec`
- `codex-workflow-worker` agent — spawnable one-task Codex wrapper
