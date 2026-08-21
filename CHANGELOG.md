# Changelog

## phpstorm v0.2.0 - 2026-08-21

### Added

- `/phpstorm:setup-xdebug [service]` — get the debugger loop working end-to-end: diagnose every
  check, walk the fixes that need a human in the IDE, re-verify until green, then prove it with one
  real pause rather than a passing config. Extracted from a private monorepo.
- `scripts/xdebug-doctor.sh` owns the checks — IDE process and listening port, both force-break
  flags, and per service the container, the loaded extension, `client_host`, `client_port`,
  `PHP_IDE_CONFIG`, the server entry and the path mapping. Three unrelated misconfigurations produce
  the identical *"Debug session was finished without being paused"*; it prints which one is live,
  with the exact fix per failure, and its `docker exec` probes run with `XDEBUG_MODE=off` so it never
  hangs on the fault it is diagnosing.
- The service rows are read from a committed `.xdebug-doctor.json` at the consuming project's root:
  container, port, server name and path mapping per service, with nothing hard-coded. There is
  nothing honest to detect here, so an absent profile exits 2 naming the marker instead of printing
  a green verdict over zero checks. A service argument that matches no row is rejected the same way.
- `--explain` follows the repo-wide contract: `services` always `profile`, `start_cmd` and
  `workspace_file` `profile` or `default`. The command reads `start_cmd` from that same output
  rather than carrying a start command of its own, so the two can never disagree about how the
  project starts; `{service}` in it is substituted per service.
- `tests/test-phpstorm-xdebug-doctor.bats` drives the CLI over `tests/fixtures/phpstorm/` — a
  declared-`start_cmd` project, a defaults-only one, and a directory with no profile — with stub
  container and port executables on `PATH`, and greps the shipped command body for the two things a
  run cannot show: that every script reference carries `${CLAUDE_PLUGIN_ROOT}`, and that no start
  command is hard-coded anywhere in it.

## toolsmith v0.1.0 - 2026-08-21

### Added

- New plugin. Four commands for the lifecycle of an agent dev tool: `/toolsmith:create` authors a
  skill, command, subagent, rule, script or hook; `/toolsmith:check` reviews one read-only;
  `/toolsmith:retire` removes it from the single place that owns it; `/toolsmith:man` prints
  tldr-style help for anything installed, or answers a project question.
  Extracted from a private monorepo.
- `scripts/toolsmith.sh --explain` is the layout adapter every command and script calls first. Three
  layouts, each chosen by a POSITIVE marker — a rulesync config file, a plugin manifest, or any
  agent-config marker — and no fallback: an unmarked directory exits 2 naming every marker it looked
  for. Layout, root, the four layer directories, `generated_dirs`, `vendor_registry` and
  `staged_registry` are always detected, so a `layout` or path key placed in `.toolsmith.json` is
  deliberately ignored; the profile carries only `sync_cmd`, `docs_cmd`, `knowledge_skill` and
  `task_runner`, each reported as `profile`, `detected:<signal>` or `default`.
- `scripts/find-skill.sh` ranks five tiers — this project, the user's own skills, installed plugins,
  marketplace clones and the public ecosystem — and its `--exact` mode compares invocations rather
  than strings, so an owned `/name` or `<plugin>:<name>` reads as taken. The remote tier runs before
  the exact verdict, and an unreachable one is a note, never a silent "free".
- `scripts/validate-dev-tool.sh` lints a layer without ever blocking (always exit 0, findings in
  `additionalContext`), with `--audit` and `--retire` modes behind the other two commands.
  `scripts/vendor-skill.sh` copies a public skill into the layout's own skills directory, records
  provenance in the layout's own record file, and refuses a name an enabled plugin stages.
- Both moved skills, `toolsmith:skill-discovery` and `toolsmith:dev-tool-authoring`, were rewritten
  against the adapter: a three-row layout table replaces the origin project's directories, the sync
  step is read from `values.sync_cmd` and reported as "none" when the project declares none, and the
  authoring scaffolds are split into one `.tmpl` set per layout.
- Companion skills are soft. The Phase 3 design dialogue uses a grilling skill when the session has
  one and asks the same five questions inline when it does not; the Phase 4 authoring standard uses a
  companion authoring skill when present and applies an eight-line checklist otherwise. The plugin's
  `dependencies` field is empty on purpose.
- Eight suites cover it: `tests/test-toolsmith-layout.bats`, `-exact`, `-skills`, plus
  `-create` (the shipped body, the soft-dependency fallbacks item by item, and each fixture layout
  driven to the template set it selects), `-find-skill` (the tiers, the offline default, and the
  ranking asserted against a committed truth table), `-man`, `-validate` (including the inversion
  where one path is a generated mirror in one layout and the authoring source in another),
  `-vendor` (offline, against a local fixture repo) and the `bun test` unit suite
  `tests/test-toolsmith-find-skill.test.ts`.

## merge-kit v0.1.0 - 2026-08-21

### Added

- New plugin. `/merge-kit:resolve` walks the conflicts of a merge or a rebase — TRIVIAL and OBVIOUS
  hunks auto-resolved against a stated fact, AMBIGUOUS ones walked one at a time — and
  `/merge-kit:verify` audits any merge, rebase or squash for work that landed on the target after
  the fork point and did not survive. Extracted from a private monorepo.
- `scripts/merge-kit.sh --explain` resolves the repo map (a committed `.merge-kit.json`, else the
  `origin` remotes of the working directory and one level of subdirectories), the test command
  (profile override, then a Makefile `test` target, then a package manager script with the runner
  read off the lockfile, then a language default) and the work directory, each with its own source
  word. The forge is never a profile field: it is read from each repo's own `origin` URL and always
  reported as `detected:origin-url`, so a repo that moves between hosts is right on the next run.
- `scripts/merge-forensics.sh` compares FORK, PRE and POST rather than the merge's own diff, so a
  change dropped without a conflict is visible. `--in-progress` autodetects a stopped merge from
  `MERGE_HEAD` and a stopped rebase from its state directory, reading POST from the index and
  worktree; a one-parent squash without `--fork` or `--source` exits 2 rather than fabricating a
  fork point. `--repo` is mandatory and every git call goes through it.
- The commands are profile-driven end to end: the repository comes from `values.repos`, the
  pull-request fetch branches on `values.forge` (`gh`, `bbkt`, `glab`, or asking when the host has
  no known CLI), the suite comes from `values.test_command` with its rung reported beside it, and
  both forensic phases of the resolve flow call `merge-forensics.sh --in-progress` — once before
  the walk, once before the commit. The worked example and the tier examples name no language.
- `tests/test-merge-kit-profile.bats` (profile precedence, every detection rung, the honest
  degrade, the ignored `forge` key, the origin-URL truth table), `tests/test-merge-kit-forensics.bats`
  (all four modes against generated fixtures) and `tests/test-merge-kit-commands.bats` (the shipped
  bodies, plus a driven check that the test command per fixture repo and the CLI per origin URL are
  what those bodies read off the JSON).

## security-audit v0.1.0 - 2026-08-21

### Added

- New plugin. `/security-audit:audit <target>` runs a pre-adoption audit of a repository, package,
  MCP server or raw script: 21 target types, nine phases applied per type, a terminal verdict under
  40 lines, a full report file with `file:line` evidence, and a final install/no-install banner.
  Extracted from a private monorepo.
- Every external tool is optional and every fallback is named in the body. Semgrep runs when
  `command -v semgrep` succeeds, otherwise an `rg` pattern pass covers the same sink list; an IDE
  search surface is used when the editor's MCP tools are in the session, ripgrep otherwise. A
  missing tool downgrades the evidence and is recorded in the report header — it never skips a phase.
- The report directory is configurable through `SECURITY_AUDIT_REPORT_DIR` and defaults to
  `${TMPDIR:-/tmp}/security-audits`, so nothing is written into an audited repo by default.
- `tests/test-security-audit-command.bats` asserts the shipped body statically — both fallbacks
  named, the cross-language sink vocabulary intact (PHP's `curl_exec` and Guzzle beside `axios`,
  `pickle`, `InsecureSkipVerify` and `reqwest`), the report directory configurable, and the command
  basename unique across every plugin.

## unslop-kit v0.6.2 - 2026-08-20

### Changed

- `unslop-formatting` names no specific project any more. The three sentences that pointed at one
  company's outbound skill now say that a project's outbound skill owns the layout of a send and
  may set its own precedence; layout > writing-style > unslop stays the ranking used here.

## unslop-kit v0.6.1 - 2026-08-20

### Fixed

- Rule 4 and the rendering table claimed a mermaid fence renders as a diagram in the Claude Code
  TUI ("user-verified 2026-08-20"). It does not: the TUI prints the source, and the reader got bare
  mermaid code under every caption. Chat visuals are now hand-drawn ASCII only. New "Drawing the
  visual" section maps content to shape (branch rail, state rail, sequence rail, box map, bar,
  edge list by layer) with two drawn examples; the mermaid row says Artifacts and HTML pages only;
  the send-check counts mermaid fences, must be 0. Hook directive, README row, plugin and
  marketplace descriptions follow.
- Converter route tested and rejected: `mermaid-ascii` 1.0.0 (npm) keeps the `A[...]` label syntax
  and repeats each node per edge; `beautiful-mermaid` 1.1.3 ships no CLI.

## unslop-kit v0.6.0 - 2026-08-20

### Changed

- Pass 3 body becomes figure-paragraphs: one emoji bold claim line, at most two prose sentences,
  at most one small numeric table, at least one italic caption above an ASCII (map/sequence/bar)
  or mermaid (state/flow/sequence) visual, a 2-7 line blockquote receipt ledger, `---` between
  paragraphs, nested lists banned outright. The CLI-rendering table gains a mermaid row and `---`
  is rehabilitated as the paragraph separator (the mermaid claim is reverted in 0.6.1). Hook
  directive, plugin description and README follow the same grammar.

## unslop-kit v0.5.2 - 2026-08-20

### Changed

- Tables must stay small and numeric: cells hold numbers, counts, identifiers, a few words at
  most. A wide table with sentence-length cells is worse than the prose it replaced, so shrink it
  or fall back to labeled paragraphs. Send-check updated to match.

## unslop-kit v0.5.1 - 2026-08-20

### Fixed

- Opt-in moves to a marker file, `~/.claude/unslop-kit.mode` (first line `0`/`1`/`force`); a
  shell export still wins per run. A `settings.json` `{"env":{...}}` block does not reach hook
  processes, and declaring `UNSLOP_HOOK` there even strips an inherited shell export from the hook
  env (observed 2026-08-20 on CLI 2.1.235), so the 0.5.0 opt-in path silently disabled the hook
  everywhere.

## unslop-kit v0.5.0 - 2026-08-20

### Changed

- Strictly opt-in: the hook defaults to OFF everywhere, so a project that advertises the plugin in
  its tracked `.claude/settings.json` never pollutes a teammate's session. `UNSLOP_HOOK=1`
  (settings.local.json env block or shell export) opts a user in, interactive sessions only;
  headless/SDK runs stay silent even then. `UNSLOP_HOOK=force` fires everywhere, which is what the
  README A/B test now uses.

## unslop-kit v0.4.1 - 2026-08-20

### Fixed

- The SessionStart hook exits silently when `CLAUDE_CODE_ENTRYPOINT` is `sdk-*` (`claude -p`, SDK
  runs, ralphex/revmux workers; verified against `claude -p` on 2026-08-20: interactive is `cli`,
  headless is `sdk-cli`). The contract formats human-facing text. `UNSLOP_HOOK=1` forces the hook
  on, headless included, which keeps the README A/B test alive; `UNSLOP_HOOK=0` still forces it
  off.

## unslop-kit v0.4.0 - 2026-08-20

### Changed

- `review:writing-style` becomes a mandatory inner doll, pass 2 (exact path:line/PR refs,
  identities for findings, verdict over feeling, first-person corrections, named uncertainty),
  gated like pstack with its own install check and fallback; its User Override Check is voided by
  the wrapper. Layout is pass 3 and drops nested lists entirely: the body is prose paragraphs, one
  emoji glyph plus bold verdict lead-in each. Precedence layout > writing-style > unslop. The hook
  names three Skill calls and checks both inner installs.

## unslop-kit v0.3.1 - 2026-08-19

### Changed

- The five unslop overrides (emoji per bullet, bold lead-ins, ...) sit under pass 2 and apply to
  chat replies only; pass-1-only surfaces keep unslop as written.
- pstack's "Adding soul" step is scoped to chat replies and prose; sends, commits, PR bodies and
  comments run the 31 patterns plus the self-audit only.
- Scope names the project's outbound skill as the orchestrator for Slack/Jira/Linear bodies (it
  loads pstack:unslop, review:writing-style and essentials:concise-writing itself, writing-style
  above unslop on conflict).

## unslop-kit v0.3.0 - 2026-08-19

### Fixed

- The inner doll was getting skipped: a session loaded `unslop-kit:unslop-formatting` and wrote
  against the abridged fallback while `pstack@cc-millz` was installed, because the hook named
  only the wrapper and the skill's "load pstack:unslop" line read as optional. Now the hook checks
  `installed_plugins.json` for `pstack@cc-millz` and demands both Skill calls in one batch
  (`unslop-kit:unslop-formatting` + `pstack:unslop`) when it is there, or says once that the
  fallback is in force when it is not; pass 1 opens with a gate ("no visible
  `Skill(skill="pstack:unslop")` call in this context window = call it now, the fallback while
  pstack is installed is a violation"); the send-check starts with that same check.


## unslop-kit v0.2.0 - 2026-08-19

### Changed

- Skill renamed `unslop-millz` → `unslop-formatting` (hook directive, README, marketplace entry follow).
- Pass 2 gains "CLI rendering, the hard rules", verified by reproducing each element in the Claude
  Code TUI: a table or fenced code block renders only at top level with a blank line on each side;
  indented under a bullet or glued to one it falls back to raw pipes / loses its fence; headings
  inside lists flatten; `---` prints literally. Send-check carries the column-zero rule.

## unslop-kit v0.1.0 - 2026-08-19

### Added

- `unslop-kit:unslop-formatting`: two-pass reply contract. Pass 1 loads `pstack:unslop` (abridged
  fallback without it) with five explicit overrides (rules 13/15/16/17/18); pass 2 is the reply
  skeleton (English Check first, TL;DR, nested bullets with one emoji glyph per top-level item,
  tables for comparisons, fenced code, `[ASSUMPTION]`, send-check). Replaces the `Format:` line
  in the personal root CLAUDE.md.
- SessionStart hook `scripts/session-start-unslop.sh`: injects the load-now directive on every
  source (startup, resume, clear, compact); `UNSLOP_HOOK=0` opts a session out. Uses
  `read -r -d ''` because bash 3.2 mis-parses apostrophes in a heredoc nested in `$( )`.
- Marketplace: `pstack` mirrored from `cursor/plugins` via `git-subdir` (`strict: false`, no
  `.claude-plugin/plugin.json` upstream).

## ralphex-revmux v0.1.1 - 2026-08-18

### Changes

- Glue: `RALPHEX_ROOT_HEAD` pins the root repo's round-1 scope (other sessions' commits landing
  mid-run stay out); `goal.md` of a fixes round lists every finding already raised in the task
  (no re-cutting the same symbol as a new major); `rounds.jsonl` carries `reported`/`expected`.
- Eval prompt: pre-existing findings are never fixed inside the loop (a fix costs a whole round) —
  they ride into the PR description; a clean round commits + signals done regardless.
- Skill + command: `--skip-finalize` on stage ② (finalize opens PRs itself), archived-plan path
  after stage ①, progress-file snapshot before relaunch, converged-but-capped wording.

## revmux-kit v0.1.1 - 2026-08-18

### Changes

- `config` template: `hard-timeout = 20m` (a 35m ceiling only lengthened a stalled xhigh agent —
  measured 35m07s stall vs ~13m longest legitimate round).

## agterm-lanes v0.2.0 - 2026-08-17

### Bug Fixes

- Headless `claude -p` children (ralphex, revmux, any `--print` run started from a Bash tool) inherit the pane's `AGTERM_*` and mint a fresh session id per run, so the session-keyed claim was free on every run: each child typed a bare `/rename` into the pane the interactive Claude owns (a lane got renamed 4× in 30 minutes), re-tinted it and re-pinned its restore command to a throwaway session. `lib.sh` gains `headless_claude()` — walks the parent chain to the nearest `claude` and reads `-p`/`--print`/`--output-format` off its argv, the only witness since the child's env carries no marker — and all three hooks refuse on it. Replaces the `AGTERM_LANE_HOOK` guard, which nothing ever set
- The lane claim is keyed on the pane (`lane-<AGTERM_SESSION_ID>`), not on Claude's session id, so a pane is named once regardless of how many sessions run through it; a lane already wearing a role emoji counts as claimed even if its sentinel is gone
- A `/rename <name>` the user typed is honoured: the transcript is checked for one before typing, and a found one is adopted as-is instead of regenerated by a bare `/rename`

## ralphex-revmux v0.1.0 - 2026-08-17

### New Features

- New plugin — revmux as ralphex's external reviewer. `scripts/bootstrap.sh` installs the
  `custom_review_script` glue (`ralphex-revmux-review.sh`: one revmux round per ralphex
  external-review iteration, `full` round on the panel profile then `fixes` rounds on the final
  profile, findings converted to `file:line - [severity, conf, sources] …` lines), the live
  `review-preflight.sh` (a real `codex exec` turn + revmux + profile resolution; stale auth is a
  stop, codex absent falls to the `fable-*` twins), the `custom_review` / `custom_eval` prompts and
  the `.ralphex/config` snippet.
- `/ralphex-revmux:run <plan>` — preflight → `ralphex --tasks-only` → `ralphex --external-only`
  (ralphex's own multi-lane review loops skipped) → converged check → reporter + optimizer.
- Agents `ralphex-result-reporter` (post-run forensics: phase timings, rounds, fixes by P1–P4,
  hiccups, hygiene) and `ralphex-optimizer` (numbered proposals with the number behind each).

## revmux-kit v0.1.0 - 2026-08-17

### New Features

- New plugin — revmux project layer for any repo: `scripts/bootstrap.sh` writes `.revmux/config`
  (`profile = sol-panel`, `hard-timeout = 35m`, `idle-timeout = 4m`), a `profile.md` template, and
  four rosters — `sol-panel` (3× codex gpt-5.6-sol xhigh + claude fable adversarial), `sol-final`
  (major floor), `fable-panel` / `fable-final` (no codex).

## essentials v0.6.1 - 2026-08-13

### Changes

- `code-style` — new Core rule **"Shape a kept comment for the eye"**, covering the *form* of a
  comment that survived the keep/cut decision (the neighbouring "No narrating comments" rule owns
  *whether* to keep it). One clause per line, broken at the comma or semicolon rather than filled
  to the column limit; markdown throughout — `*emphasis*` on the pivot word, `**strong**` on the
  load-bearing claim, backticked identifiers, `-` bullets for a reasoning chain. Explicitly
  instructs using markdown **even though PHPDoc / Javadoc / JSDoc render none of it** and pass
  `*text*` through as literal asterisks: the reader is a human scanning source, not a rendered popup

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
