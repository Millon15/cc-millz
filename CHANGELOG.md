# Changelog

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
