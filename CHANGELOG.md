# Changelog

## peer-chat v0.4.0 - 2026-09-10

The first long run (a devbox spec and its Phase A, 2026-09-09) was audited against both transcripts:
a "fixed" that never re-ran the peer's fixture, a question the sender's own search could have
answered, a 29-minute silence on an open ask, a dropped ask, a silent reversal, zero pushback on
claims neither side had checked, and reasoning written to `.txt` files because the message cap
did not fit it. Every change below is keyed to one of those.

### Changed

- Message shape, both skills: the 50-character and 20-line caps are gone. A message is as long as
  the thought needs, one segment per line; `peer-chat-paste.py` wraps prose at `PEER_CHAT_WRAP`
  columns (default 50) on a word boundary and leaves a token with no spaces whole. "One claim per
  message" becomes "one thread per message", the steps of the reasoning included.
- Artifacts, both skills: prose never goes to a file. `tmp/peer-chat/<slug>/` holds scripts,
  outputs, queries, pages, fixtures and diffs only; a `.md` or `.txt` of reasoning there is a
  violation the peer names. The "markdown file when reasoning does not fit a line" clause is gone.
- Proofs, both skills: a runtime claim that either agent disputes goes through `/plan:research` or
  `plan-research.sh`; an undisputed measurement stays a hand script. "Fixed" is claimed only by
  quoting the re-run of the peer's own proof (`plan-research.sh --verify`), otherwise
  `🎯 unproven: fix applied, fixture not re-run`.
- Manners, both skills: a reversal is named before the new claim (`🎯 I said X; Y is right because
  Z`); a peer's claim is accepted only as `accepted: "<their words>"; checked <path:line>`; one tool
  call of your own before any `❓` about the code.

### Added

- The ask ledger in `peer-chat-paste.py`: `--slug <topic>` (or `PEER_CHAT_SLUG`) stamps every `❓`
  with a script-issued, topic-scoped id (`#claude-004`) and records it in
  `tmp/peer-chat/<topic>/asks.tsv` after delivery is confirmed. The peer's next send must carry
  `#id answered`, `#id deferred(<when>)` or `#id declined(<why>)` for each new ask or the send is
  refused before anything is written, the questions listed; a `--message-file` send that is
  refused gets its spool file restored. `deferred` keeps the ask open and, after
  `PEER_CHAT_DEFER_MINUTES` (default 20), the deferrer's next send opens with `overdue: #id`.
  Delivery and disposition are separate columns. Without `--slug` the script warns and tracks
  nothing.
- `peer-chat-paste.py` warns on a `❓` with no `🔎` anywhere in the message, naming the rule.
- The send report gains `asks` (ids issued) and `disposed` (ids answered, deferred or declined).

## peer-chat v0.3.0 - 2026-09-09

### Added

- `scripts/peer-chat-paste.py` — the multi-line send. The vendored transport types keystrokes and a
  typed newline submits, so every message became one line; in a thin split pane that is a wall the
  user cannot follow. The paste sender loads `peer-chat.py` as a module for the same target and
  composer checks, refuses a composer that is not empty, puts the body in through a bracketed
  paste (`agtermctl session paste`, the clipboard saved and restored around it), confirms the last
  line is visible, sends the submit key and confirms the composer cleared. `--message-file` is the
  transport's own spool contract, so the Codex side keeps `--prepare-message`.
- Message shape, both skills: one segment per line, a blank line between segments, lines under 50
  characters, the whole under 20 lines; `peer-chat.py` is kept for one-line notes and `--queue`.
- The installer copies the paste sender onto PATH and appends its one approval rule for Codex;
  `--check` reports both.

## plan v0.2.0 - 2026-09-10

### Added

- The proof contract. Every artifact prints `PROOF <case>: <got>` lines and the proover writes
  `tmp/a/<slug>/<n>-proof.json` beside it: the run line, the artifact and raw output paths, the
  tree sha, and each case with `expect` (what the requirement demands) and `got`. The honesty gate
  gains a fifth question; a proof without a contract is INCONCLUSIVE. An `expect` is never edited
  in place: a change is a reviewed revision (`case`, `old_expect`, `new_expect`, `requirement`,
  `reviewer`) appended to `revisions`, and unresolved intent goes to the user.
- `plan-research.sh --slug <slug> --verify <n>` re-runs one proof against its contract: exit 0 when
  every case matches, 1 on a regression with the cases listed, 2 when the artifact fails to run,
  3 with no usable contract (missing, no cases, no run line, or a revision missing a field). Every
  run is appended to `<n>-proof.runs.tsv` with the tree sha and the contract's sha256, and the
  verify output lands in `<n>-proof.verify.out`. The `peer-chat` skills quote that exit line for a
  "fixed" claim.

## plan v0.1.1 - 2026-09-09

### Fixed

- `plan-research.sh` no longer glob-expands a `claude_args` allow-list entry such as `Bash(docker:*)`
  against the working directory before handing it to claude.

## plan v0.1.0 - 2026-09-09

### Added

- `plan` — `/plan:research` and its two subagents, extracted from a private monorepo and made neutral:
  `answer-researcher` (Sonnet, read-only, facts with `file:line` cites and suggested hypotheses) and
  `answer-proover` (Sonnet, runnable artifacts under `tmp/a/<slug>/` that try to DISPROVE each claim,
  honesty gate, raw output kept as `<n>-proof.out`). The command is model-invocable, so a skill such as
  peer-chat can fire it on a contested claim. Project facts (skills to load, container, test-runner
  and read-only DB command shapes, knowledge indexes) come from a committed `.plan.json`.
- `scripts/plan-research.sh` — the same pipeline headless (`claude -p "/plan:research slug=<slug> …"`
  with every MCP server off), so a peer agent or a CI job can ask for a proof and read
  `tmp/a/<slug>/answer.md`. Permissions stay Claude's: the default is `--permission-mode acceptEdits`,
  a project widens it through `claude_args`. `--explain` under the marketplace contract; `--install`
  writes a launcher onto `PATH` that resolves the newest plugin copy; `--check` is the preflight. No
  Codex approval rule is written; that decision is the user's.

## peer-chat v0.2.0 - 2026-09-09

### Added

- Message shape, both skills: one line the user can follow in the pane, as an emoji ledger
  (`🎯` claim, `🔎` evidence, `📎` artifact with how to run it and what it showed, `❓` the one
  question, `🏁` closing), under 700 characters, one claim per message, no "round n of m" staging.
- Artifacts, both skills: code, data and pages go to `tmp/peer-chat/<slug>/` under the repo root as
  `NN-<agent>-<what>.<ext>`; a markdown file only when reasoning does not fit a line, and the chat line
  still carries the claim. The artifact dirs (`tmp/peer-chat/`, `tmp/a/`) are outside the sole-writer
  rule.
- Proofs, both skills: a contested claim about runtime behaviour gets a proof before the next send —
  Claude through `/plan:research` (plugin `plan@cc-millz`), Codex through `plan-research.sh` or a
  script of its own; an unproved claim goes out marked `🎯 unproven:`.
- `peer-chat-spawn.sh --restart` — quits the Codex already in the right pane with one `/quit` line and
  starts a fresh one, for a Codex that predates a skill update; reports `{"state":"restarted"}`, exit 1
  with a read-back hint when Codex ignores the quit.

### Fixed

- The spawn suite's missing-tool test no longer passes by accident when a real `peer-chat.py` sits in
  `~/.local/bin`.

## peer-chat v0.1.0 - 2026-09-08

### Added

- `peer-chat` — umputun's agterm `two-agent-chat` cookbook recipe as a plugin: `peer-chat.py` and its
  135-test unittest suite vendored byte for byte from `umputun/agterm@14858ea` (MIT), the Claude-side
  skill edited, the Codex-side skill shipped under `codex/` for the installer to place.
- `scripts/peer-chat-spawn.sh` — the one departure from upstream, which leaves starting Codex to the
  human. Opens the split when it is missing, waits for a shell prompt to draw, types the single codex
  launch line with this pane's session id injected through `shell_environment_policy`, and waits until
  `tree --json` reports codex as the right pane's foreground. Refuses a busy right pane, a Claude that
  is not the main pane's foreground, and anything outside agterm; `--explain` prints `codex_args`,
  `codex_command`, `claude_command` and `start_timeout` with their sources (env, a committed
  `.peer-chat.json`, or default) under the marketplace's `--explain` contract.
- `scripts/peer-chat-install.sh` — copies `peer-chat.py` onto `PATH` (a copy, since a symlink into the
  plugin cache dies on the next version bump), installs the Codex skill into `~/.codex/skills/peer-chat/`
  and appends the two `prefix_rule` approval lines to `~/.codex/rules/default.rules` once; `--check`
  is the skill's preflight.
- The skill's description gains an autonomous branch: fire on your own when a design has two
  defensible options, a root cause has not been disproved, a diff ships unreviewed, or an investigation's
  reading can be split — and say so in one line before the first send.
- `scripts/sync-upstream.sh` re-vendors the verbatim files and stages upstream's two skill files for a
  hand merge; `UPSTREAM.md` pins the commit.
- Tests: `tests/test-peer-chat-spawn.bats` drives the spawn against a stubbed `agtermctl` state machine
  and asserts what is typed and, for a pane already running codex, what is not; `test-peer-chat-install.bats`
  proves idempotence against a temp `CODEX_HOME`; `test-peer-chat-upstream.bats` runs the vendored suite.

## unslop-kit v0.8.0 - 2026-09-08

### Added

- `unslop-kit:unslop` — poteto's unslop body vendored byte for byte under a model-facing frontmatter
  (MIT, Lauren Tan). Upstream cursor/plugins PR #300 (2026-09-01, `73f8be4`) set
  `disable-model-invocation: true` on `pstack:unslop`, which drops it from the model's skill list and
  makes the Skill tool answer "cannot be used with Skill tool due to disable-model-invocation". The
  kit's pass 1 needs the 31 patterns reachable by the model and by other skills, so it ships its own
  copy. Vendored from pstack `71ed0d1076fe`; rule ids 3-33 unchanged.
- `scripts/sync-unslop.sh` — re-vendors the skill from the installed `pstack@cc-millz` (path from
  `installed_plugins.json`, `CLAUDE_CONFIG_DIR`-aware) or from a path argument, and writes a provenance
  line with the upstream sha and date. `--check` exits 1 on drift, 2 when no source is found.
- `tests/test-unslop-kit-sync.bats` covers the render, the provenance line, `--check` and the no-source
  exit.

### Changed

- The SessionStart hook and `unslop-formatting` name `Skill(skill="unslop-kit:unslop")` for pass 1.
  The pstack install check and the "fallback while pstack is installed is a violation" wording are
  gone: the pass-1 skill always ships with the kit, so only the writing-style call stays gated.
- `unslop-formatting` no longer scopes pstack's "Adding soul" step: upstream `e8d856f` (2026-09-07)
  removed that step, so the paragraph overrode nothing.
- `pstack@cc-millz` is no longer a runtime requirement of unslop-kit; it is needed only to re-run the
  sync script.

## merge-kit v0.2.0 - 2026-09-04

### Added

- `/merge-kit:resolve <repo>` — a bare repo alias with no mode word now adopts whatever operation is
  already stopped in that repository. The strategy, SOURCE and TARGET are read from `.git/MERGE_HEAD`
  or from `.git/rebase-merge/{head-name,onto}`, the same files `merge-forensics.sh --in-progress`
  reads, so the walk and the audit agree on the three references by construction. The form was
  already what a caller mid-rebase reached for; it was not in the input table, so everything below it
  ran on inference.

### Fixed

- The rebase lane was one sentence, and every phase after it was written for a merge. It is now a
  loop that is spelled out: per stopped step, Phase 3.5, the walk, Phase 5.5, then
  `rebase --continue`. Phase 5 is explicitly outside that loop and runs once, after the last step
  lands, because a branch mid-rebase carries a half-replayed history whose failures say nothing about
  the result and whose greens prove nothing either.
- Phase 5.5 could not run at all where it mattered. `--in-progress` reads the rebase state directory
  and the final `rebase --continue` deletes it, so an audit deferred to the end of the rebase exits 2
  — correctly, since a rebase leaves no merge commit for the finished form to audit either. The phase
  now says to run it before every `--continue`, and names the only honest recovery when the state is
  already gone: a hand read of `git diff {TARGET}..HEAD` for deletions of lines the target owns.
- Phase 2 told the run to confirm the current branch is SOURCE, which a stopped rebase can never
  satisfy: HEAD is detached by design and SOURCE lives in `rebase-merge/head-name`. The phase is now
  skipped outright for an adopted or stopped operation, where fetching and pulling are a way to lose
  the state rather than a preparation for it.
- Phase 6 assumed a `MERGE_MSG` that a rebase never writes. Steps 1 to 4 are now marked merge-only,
  since each rebase step was already committed by its own `--continue`, and the no-push rule covers
  the adopted mode alongside LOCAL.

## unslop-kit v0.7.1 - 2026-08-24

### Fixed

- The receipt ledger printed two grey bars. The skill named the ledger by the glyph the TUI paints
  for a blockquote, "a `▎` blockquote ledger", in the pass-3 recipe, in the CLI rendering table and
  in the send-check, so replies typed `> ▎ fact` and the terminal drew its own bar beside the
  literal one. All three mentions now say what to type: one plain `>` and a space per line, no bar
  glyph inside the quote, no nested `> >`. A new send-check line catches both shapes and keeps `▌`
  legal inside a bar visual.

## gws-workspace v0.1.0 - 2026-08-21

### Added

- New plugin. One skill and six references drive Google Workspace through the `gws` CLI instead of
  a Workspace MCP server: the `<service> <resource> <method>` call shape, the shared flag set, and
  per-service tables for Docs, Sheets, Slides, Tasks and Drive, plus the `+read` / `+write` /
  `+append` / `+upload` helpers and the `gws schema` discovery commands that answer a method's
  required params without a web search. Extracted from a private monorepo.
- The Google Docs comment finding travels intact, because it is the part that costs an afternoon to
  rediscover: `gws drive comments create` posts an **unanchored** card whatever anchor you supply.
  Drive echoes the anchor back and Docs then renders the comment as "Original content deleted" —
  for a Docs-API `createNamedRange` id and for the documented JSON region alike — so a highlighted
  inline comment is a browser-UI path only, and `anchor != null` on a listed comment proves nothing
  about how it was created. The reference carries the working recipe for both paths, the focus traps
  that put your text into the document body instead of the comment box, and the export-and-`diff`
  check that proves the body came out untouched.
- Authentication is a three-command ladder rather than a link. The private version pointed at an
  internal auth guide that is not coming along, so the skill now names `gws auth setup` — the CLI's
  own help describes it as configuring the GCP project and OAuth client, and it shells out to
  `gcloud` — beside the `gws auth login` and `gws auth status` it already carried. A fresh machine
  is covered end to end by the shipped body.
- Nothing is written beside tracked source. The five scratch paths that were repo-relative — a
  downloaded `.pptx`, the long-comment helper, the stray zero-byte `download.html` that
  `comments delete` drops into the current directory, and the before/after export the verify step
  diffs — now resolve through `${TMPDIR:-/tmp}`, so an export lands somewhere every user can write.
- The safety rules are unchanged and are the reason this is safe to publish: confirm with the user
  before any write or delete, rehearse destructive operations with `--dry-run`, never print secrets.
- The plugin ships **no command and no script**, so it claims no `/name` and adds nothing to PATH.
  The one executable involved is the third-party `gws` binary from the `@googleworkspace/cli` npm
  package, named in the README as a hard requirement with no fallback and never installed for you.
- `tests/test-gws-workspace-body.bats` holds the shipped bodies to all of that — the three auth
  commands, the anchored-comment finding, the safety rules, the six references and the links into
  them, the empty `dependencies`, the absence of any command or executable, and the absence of any
  origin-project path literal, absolute home path or repo-relative scratch dir. There is no entry
  script to drive and the one binary belongs to somebody else, so the suite is a static grep paired
  with a captured smoke log of the real CLI, exactly as `security-audit` was.

## short-video-reader v0.1.0 - 2026-08-21

### Added

- New plugin. One skill and one script read ONE short video end-to-end from local artifacts and
  report what is *visible*, never what is guessed: acquisition from a URL or a local file with its
  provenance, an `ffprobe` stream inventory, scene-cut and interval frames collected into contact
  sheets, the captions the source already carried, `--zoom` close-ups, and a transcript only when a
  free offline speech-to-text route already exists on the machine. Nothing authenticates, nothing is
  installed for you, and nothing leaves the machine. Extracted from a private monorepo.
- `scripts/short-video-read.sh --explain` resolves the scratch base through three rungs and reports
  which one answered: the `SHORT_VIDEO_DIR` environment variable (`detected:env`), a `workdir` in a
  committed `.short-video-reader.json` found by walking up to `$HOME` or `/` (`profile`), then a
  `short-video-reader` subdirectory of the OS temp dir (`default`) — a directory, never an error,
  because a user with no project is not a usage mistake. The environment leads so a committed
  profile stays overridable for one run without editing a committed file, and a relative value
  anchors to the profile's own directory rather than to the current one, so one profile answers with
  one path from every directory. `--probe` stays as the human twin, printing from the same detection
  pass, and the resolved base feeds `BASE_DIR`, the delete guard, `--zoom`'s path printing, the model
  cache and `report.json` alike.
- The `--remove-tmp` guard is an ownership proof, not a path prefix. A directory is deleted only when
  it carries `.short-video-reader-run` holding `short-video-reader/run/v1` — written the moment this
  tool created it, so a run killed halfway is still recognisably its own — *and* lies under the base
  the run resolved. A `report.json` proves nothing (several test reporters write one), a pre-existing
  directory without the marker is refused rather than adopted, and a base resolving to `/`, to
  `$HOME` or to a directory carrying a `.git` entry is rejected with the offending rung named.
- `ffmpeg`, `ffprobe` and `jq` are hard requirements, `yt-dlp` is hard for URL input only, and each
  missing one exits 3 with the line that installs it. whisper stays soft: with no local route the
  audio is reported `not_analyzed` with the reason and the read continues on frames and captions.
- Three suites cover it: `tests/test-short-video-workdir.bats` drives every rung and asserts the
  resolved absolute path, not only the source word; `tests/test-short-video-guard.bats` covers the
  marker, the refusals and the base sanity check; `tests/test-short-video-explain.bats` holds the
  shipped skill body to the toolchain it declares and drives the exit-3 paths against a `PATH`
  carrying the stub directory alone. Fixture trees are BUILT at setup under a redirected `HOME`, so
  no case depends on a directory git cannot carry.
- Publication fixed one bug the suites could not see: `--trim-filenames 80` trims the whole expanded
  output path rather than the file name, so on the OS-temp rung — a macOS `$TMPDIR` is around fifty
  characters before the plugin's own subdirectory — yt-dlp wrote a real download to a sibling of the
  run directory and the reader reported "produced no media file" over a clip that had just
  downloaded fine. The bound now lives in the output template, `%(id).80B`, where it applies to the
  only unbounded part.

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
