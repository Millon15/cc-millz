# 🎓 session-learnings

Learn from finished Claude Code sessions without letting a single session teach Claude anything on its own.

- **SessionEnd hook** queues the ended session in under 100 ms and exits; the 1.5 s SessionEnd budget never sees an LLM call.
- **launchd worker** turns the transcript into a redacted digest, skips sessions with no failure→fix cycle or human correction, and asks a tool-less `claude -p` for at most five candidate lessons.
- **Deterministic merger** validates the JSON, scrubs secrets, keeps a lesson only when its evidence line is a human turn or a successful Bash run, and writes a draft card. Everything else lands in quarantine.
- **A ledger scores every lesson**: sightings on separate days, projects, human evidence and applications raise it, failed applications and contradictions lower it. Status is recomputed from the ledger each time, so demotion is automatic.
- **Drafts are invisible to Claude**: they live in `~/.claude/learnings/`, a path Claude Code never loads. Only candidates surface, and only when Claude calls the `recall` skill, marked unreviewed.
- **`/session-learnings:review`** walks ready candidates and challenged stable lessons with you, writes a skill only after you approve the exact content and destination, and records the decision in the ledger.
- **A weekly usage report** counts skill and command loads, project script runs, repeated hand-typed commands and knowledge-path reads from the last 7 days of transcripts. Fixed rules turn it into proposals the same review walks, one decision each.
- **An opt-in weekly agent** opens the review in a background agterm session when a proposal or a ready lesson is waiting.

## 📦 Install

    /plugin install session-learnings@cc-millz

Installing the plugin enables the hook, which only queues jobs. Nothing calls a model until you load the worker:

    bash "$(cat ~/.claude/learnings/plugin-root 2>/dev/null || echo <plugin dir>)/scripts/sl-install.sh"

| Command | Effect |
|---------|--------|
| `sl-install.sh` | create the store, write the shim and the launchd plist, load the worker agent |
| `sl-install.sh --review-weekly` | the same, plus the weekly review agent ([📊 Weekly usage review](#-weekly-usage-review)) |
| `sl-install.sh --check` | exit 0 when the worker is loaded and the review agent, if installed, is too |
| `sl-install.sh --uninstall` | unload both agents and remove their plists; the store stays |
| `sl-install.sh --explain` | resolved config as JSON, no side effects |

Requires macOS (launchd), `jq`, `perl`, Python 3 (standard library), and the `claude` CLI on the `PATH` captured at install.

launchd does not inherit your shell: `sl-install.sh` writes `PATH`, `CLAUDE_CONFIG_DIR` and the `SESSION_LEARNINGS_*` settings from the configuration table below, when set at install time, into the agent's plist. Re-run it after changing one.

## 🔄 How a session flows

```text
SessionEnd ──▶ queue/<session>.json ──launchd──▶ sl-worker.sh
   digest (classes from the transcript, redacted, then truncated)
   signal? ── no ──▶ done/ skipped:no-signal
   sl-apply.sh: recall runs and Skill calls in this transcript ──▶ applied events   (before the signal gate)
   sl-extract.sh: claude -p --safe-mode --no-session-persistence --tools "" --output-format json --json-schema …
   sl-dedup.sh: exact match or tool-less judge ──▶ links (same, refines, contradicts)
   sl-merge.sh: schema, secrets, denylist, evidence class, links ──▶ ledger.jsonl ──▶ cards
every worker run that sweeps: sl-usage.sh ──▶ sl-ledger.sh maintain (TTL, stale) ──▶ done/ rotation
```

- Only interactive sessions count: the transcript's `entrypoint` must be `cli` or `claude-desktop`, so `claude -p` runs (ralphex, revmux, the extractor itself) are skipped.
- Every job leaves `queue/`: success or skip to `done/`, failure to `failed/`; the hourly run re-queues failures up to three attempts and recovers jobs a crashed worker left in `processing/`.
- The hourly run also picks up sessions whose SessionEnd never fired (a closed terminal) once they have been idle for an hour.

## 🪜 Lifecycle

```text
[draft] ──2 days, score ≥ 2──▶ [candidate] ──review approve──▶ [stable] ──review──▶ [deprecated]
   ▲                               │
   └──────score < 2 (demotion)─────┘          review reject ──▶ [rejected]
[draft], [quarantine] idle 90 days, [candidate] idle 180 days ──maintain──▶ [expired] ──new sighting──▶ revived
```

| Rule | Value |
|------|-------|
| score | days + 0.5 × (projects − 1) + 0.5 if a human turn is evidence + applied_ok − 1.5 × applied_fail − 2 × open contradictions |
| global candidate | also needs sightings in 2 projects, so recall never carries one repository's lesson into every other |
| `ready` flag | candidate with 2 successful applications or sightings on 3 days; a global one also needs 2 projects |
| `failing` flag | stable with 2 failed applications since promotion |
| `stale` flag | stable with no skill usage and no application for 60 days |

Flags only order the review queue. Nothing but an approved review decision writes, changes or deprecates a skill file.

`sl-ledger.sh list [--project=SLUG] [--status=a,b]` prints one JSONL row per card; `sl-ledger.sh event --type=promoted|rejected|deprecated --id=lsn-…` records a decision.

## 📊 Weekly usage review

```text
transcripts, last 7 days ──sl-stats.sh report──▶ usage/<year>-W<week>.json
                                                    │ fixed rules
                                                    ▼
proposals.jsonl decisions ──sl-stats.sh proposals──▶ open proposals ──▶ /session-learnings:review
launchd, weekly ──sl-review-launch.sh──▶ agterm session: claude "/session-learnings:review"
```

| Command | Effect |
|---------|--------|
| `sl-stats.sh report [--days=7] [--if-stale]` | scan transcripts and subagent transcripts, write this ISO week's report, print its path; `--if-stale` keeps an existing one |
| `sl-stats.sh proposals [--project=SLUG] [--status=open\|all]` | one JSONL row per proposal from the newest report and the recorded decisions |
| `sl-stats.sh decide --id=prp-… --type=accepted\|rejected\|deferred [--note=…]` | record a decision |
| `sl-stats.sh --explain [--project-dir=DIR]` | the knowledge paths and script dirs resolved for a project |
| `sl-review-launch.sh [--dry-run]` | refresh the report, then open the review in agterm when something waits |

A project lists what to count in `.session-learnings.json` at its root, committed:

```json
{"knowledge_paths": ["docs/"], "script_dirs": ["bin/"]}
```

Without the file, `docs/` is a knowledge path and `bin/` and `scripts/` are script dirs when they exist.

A read is a `Read`, `Grep` or `Glob` call on a path under a knowledge path, or an `rg`, `grep`, `sed`, `cat`,
`head`, `ls` or `find` argument there. A script run is a command starting with a file in a script dir or ending in
`.sh`, `.py`, `.mjs` or `.ts`, also behind `bash`, `python3`, `node`, `bun` or `uv run`; inline code (`bash -c`,
`python -c`) never counts as a script. A hand-rolled command is anything else, minus shell syntax, readers, text
filters (`awk`, `cut`, `sort`, …), shell builtins, and interpreter calls without a matching project script
(including inline code, `-m` modules and stdin); a command given as a path is counted by its file name.

| Proposal | Rule |
|----------|------|
| `knowledge-gap` | a project with 10 or more sessions where under 25% read the knowledge path |
| `unread-areas` | directories directly under a knowledge path that no session read |
| `dormant-skill` | a skill with a usage counter whose last load is older than 30 days |
| `hand-rolled` | a command head typed 10 or more times across 3 sessions; top 5 per project |

The report stores counts and paths. A repeated command keeps its first word, plus the second only when it is a simple
word or flag (letters, digits, `-`, `_`: `gh pr`, `docker exec`, `curl -H`); a URL- or path-shaped second word and
every later word are dropped, but a plain-word value in second place is kept. `proposals` prints at
most 5 open rows per kind and project (`dormant-skill`: 5 overall), dormant skills by lifetime loads and
hand-rolled heads by runs, so the next ones surface as you decide these; `--status=all` lists every row. A proposal id is stable across weeks: `accepted` closes it,
`rejected` hides it for 90 days, `deferred` brings it back next week.

The weekly agent runs `sl-review-launch.sh`. When neither an open proposal nor a ready lesson waits, it does nothing.
When a review session is already open (found by its command line, since a pane-labelling hook may rename it), it
does nothing. Otherwise it opens a session in the agterm workspace `session-learnings` without taking focus, marks it
blocked in the sidebar and sends one notification. When agterm is unreachable it only notifies.

## 🗂 Store

`${SESSION_LEARNINGS_HOME:-~/.claude/learnings}`

    ledger.jsonl                                   authoritative events, one per session × lesson
    global/{drafts,candidates,stable,quarantine,archive}/lsn-<hash>.md
    projects/<slug>/{drafts,candidates,stable,quarantine,archive}/lsn-<hash>.md
    queue/ processing/ done/ failed/ work/          worker state
    done.jsonl                                     done/ jobs older than 30 days
    failed.jsonl                                   failed/ jobs out of retries for 30 days
    ledger.archive.jsonl                           events of lessons compacted out of ledger.jsonl
    .notified-ready                                ready ids a notification already announced
    usage/<year>-W<week>.json                      weekly usage reports
    proposals.jsonl                                decisions on usage proposals
    worker.log  launchd.out  launchd.err  (+ .1)
    review.out  review.err                         weekly review agent output

Every hourly sweep keeps the store bounded:

- failed jobs out of retries for 30 days fold into `failed.jsonl`, and the sweep never re-queues their sessions;
- files in `work/` older than 7 days are removed;
- `worker.log`, `launchd.out` and `launchd.err` over 1 MiB rotate into one `.1` generation (copy, then truncate in
  place, so launchd keeps its open descriptors);
- `sl-ledger.sh compact` moves the events of rejected, deprecated or expired lessons whose last event is older than
  365 days into `ledger.archive.jsonl` and removes their cards; a later sighting starts a fresh draft. `--keep-days`
  and `--now` run it by hand;
- new ready candidates trigger one desktop notification, "N lessons ready: /session-learnings:review". An id counts
  as announced only after delivery succeeds, so a failed notification is retried on the next sweep.

A failed cleanup step is logged and the run goes on.

A card is markdown with JSON frontmatter (valid YAML): id, scope, kind, status, flags, score, trigger, claim, fingerprint, evidence (session, transcript line, excerpt, source class, model proof), counts, proposed revisions, first/last seen, quarantine reasons, and skill and path once promoted.

## ⚙️ Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `SESSION_LEARNINGS_HOME` | `~/.claude/learnings` | store root |
| `SESSION_LEARNINGS_MODEL` | `claude-opus-5-5` | extractor and dedup judge model, see below |
| `SESSION_LEARNINGS_EXTRACTOR` | `claude` | extractor executable, one path, never shell-evaluated |
| `SESSION_LEARNINGS_TIMEOUT` | `120` | extractor timeout, seconds (1-3600) |
| `SESSION_LEARNINGS_MIN_HUMAN` | `3` | human turns a session needs before extraction |
| `SESSION_LEARNINGS_DIGEST_BUDGET` | `300000` | digest size in bytes; over it, human and Bash rows are kept before reads and prose |
| `SESSION_LEARNINGS_NOTIFY` | unset | notifier executable, called with the message as its one argument; `off` disables. Unset: `agtermctl notify`, then `osascript` |
| `SESSION_LEARNINGS_REVIEW_WEEKDAY` | `1` | weekly review day for `--review-weekly`, launchd numbering (0 and 7 = Sunday) |
| `SESSION_LEARNINGS_REVIEW_HOUR` | `10` | weekly review hour, local time |
| `SESSION_LEARNINGS_REVIEW_CWD` | `$HOME` | directory the review session starts in, so project-scoped skills land in that repository |
| `CLAUDE_LEARN_SKIP` | unset | `1` turns the hook, the worker and the review launcher off for that process |

### Choosing the model

The default is Opus because a blind eval preferred it. On the 10 most recent sessions with signal, Haiku 5.5 and
Opus 5.5 extracted lessons from the same digests, and a grader from another model family, who never saw the arm
names, picked an Opus set as the best one in 9 of 10 sessions. Haiku costs a tenth as much per session ($0.10 vs
about $1.00 at API prices, with digests of 30-300 KB), and its share of lessons that are useful, non-obvious and
backed by the evidence was close: 70% against 72%. On a subscription a `claude -p` call spends plan quota, not
dollars.

Re-run the comparison on your own sessions before you change the default:

```bash
scripts/sl-eval.sh --out=/tmp/sl-eval --sessions=10 \
  --arm=haiku:claude-haiku-5-5:prompts/extract.md --arm=opus:claude-opus-5-5:prompts/extract.md
```

It writes `blind.md` (arms under shuffled labels), `key.json` and `costs.tsv`; grade `blind.md` before you open the
key. Then set `SESSION_LEARNINGS_MODEL` and run `sl-install.sh` again, which writes it into the launchd agent.

## 🛡 Safety

- The extractor has no tools, no MCP, no settings, no session persistence, an empty temp cwd, and its child env sets `CLAUDE_LEARN_SKIP=1`.
- Secrets are scrubbed before truncation, before the model, and again before a card is written; any hit quarantines the card.
- A lesson backed only by tool output (a file read, a web page, a peer agent's message) is quarantined: memory-poisoning attacks plant "successful experiences" exactly there.
- Claims about `rm`, `chmod 777`, `--no-verify`, `curl | sh`, disabling TLS or verification, or editing permissions and hooks are quarantined.
- The dedup judge runs with the same isolation as the extractor and decides only how two lessons relate; it never upgrades evidence. A quarantined lesson never links.
- Recall output is marked unreviewed and the skill tells Claude to treat every claim as a hypothesis. Application outcomes are heuristic telemetry, not proof.
- Nothing writes a skill, CLAUDE.md or rules file except `/session-learnings:review` after your explicit approval.
