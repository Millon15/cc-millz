# 🎓 session-learnings

Learn from finished Claude Code sessions without letting a single session teach Claude anything on its own.

- **SessionEnd hook** queues the ended session in under 100 ms and exits; the 1.5 s SessionEnd budget never sees an LLM call.
- **launchd worker** turns the transcript into a redacted digest, skips sessions with no failure→fix cycle or human correction, and asks a tool-less `claude -p` for at most five candidate lessons.
- **Deterministic merger** validates the JSON, scrubs secrets, keeps a lesson only when its evidence line is a human turn or a successful Bash run, and writes a draft card. Everything else lands in quarantine.
- **A ledger scores every lesson**: sightings on separate days, projects, human evidence and applications raise it, failed applications and contradictions lower it. Status is recomputed from the ledger each time, so demotion is automatic.
- **Drafts are invisible to Claude**: they live in `~/.claude/learnings/`, a path Claude Code never loads. Only candidates surface, and only when Claude calls the `recall` skill, marked unreviewed.
- **`/session-learnings:review`** walks ready candidates and challenged stable lessons with you, writes a skill only after you approve the exact content and destination, and records the decision in the ledger.

## 📦 Install

    /plugin install session-learnings@cc-millz

Installing the plugin enables the hook, which only queues jobs. Nothing calls a model until you load the worker:

    bash "$(cat ~/.claude/learnings/plugin-root 2>/dev/null || echo <plugin dir>)/scripts/sl-install.sh"

| Command | Effect |
|---------|--------|
| `sl-install.sh` | create the store, write the shim and the launchd plist, load the agent |
| `sl-install.sh --check` | exit 0 when the agent is loaded |
| `sl-install.sh --uninstall` | unload the agent and remove its plist; the store stays |
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

## 🗂 Store

`${SESSION_LEARNINGS_HOME:-~/.claude/learnings}`

    ledger.jsonl                                   authoritative events, one per session × lesson
    global/{drafts,candidates,stable,quarantine,archive}/lsn-<hash>.md
    projects/<slug>/{drafts,candidates,stable,quarantine,archive}/lsn-<hash>.md
    queue/ processing/ done/ failed/ work/          worker state
    done.jsonl                                     done/ jobs older than 30 days
    worker.log

A card is markdown with JSON frontmatter (valid YAML): id, scope, kind, status, flags, score, trigger, claim, fingerprint, evidence (session, transcript line, excerpt, source class, model proof), counts, proposed revisions, first/last seen, quarantine reasons, and skill and path once promoted.

## ⚙️ Configuration

| Variable | Default | Meaning |
|----------|---------|---------|
| `SESSION_LEARNINGS_HOME` | `~/.claude/learnings` | store root |
| `SESSION_LEARNINGS_MODEL` | `claude-haiku-5-5` | extractor and dedup judge model |
| `SESSION_LEARNINGS_EXTRACTOR` | `claude` | extractor executable, one path, never shell-evaluated |
| `SESSION_LEARNINGS_TIMEOUT` | `120` | extractor timeout, seconds (1-3600) |
| `SESSION_LEARNINGS_MIN_HUMAN` | `3` | human turns a session needs before extraction |
| `SESSION_LEARNINGS_DIGEST_BUDGET` | `300000` | digest size in bytes; over it, human and Bash rows are kept before reads and prose |
| `CLAUDE_LEARN_SKIP` | unset | `1` turns the hook and the worker off for that process |

## 🛡 Safety

- The extractor has no tools, no MCP, no settings, no session persistence, an empty temp cwd, and its child env sets `CLAUDE_LEARN_SKIP=1`.
- Secrets are scrubbed before truncation, before the model, and again before a card is written; any hit quarantines the card.
- A lesson backed only by tool output (a file read, a web page, a peer agent's message) is quarantined: memory-poisoning attacks plant "successful experiences" exactly there.
- Claims about `rm`, `chmod 777`, `--no-verify`, `curl | sh`, disabling TLS or verification, or editing permissions and hooks are quarantined.
- The dedup judge runs with the same isolation as the extractor and decides only how two lessons relate; it never upgrades evidence. A quarantined lesson never links.
- Recall output is marked unreviewed and the skill tells Claude to treat every claim as a hypothesis. Application outcomes are heuristic telemetry, not proof.
- Nothing writes a skill, CLAUDE.md or rules file except `/session-learnings:review` after your explicit approval.
