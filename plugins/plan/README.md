# 🔬 plan

    /plugin install plan@cc-millz
    bash ~/.claude/plugins/cache/cc-millz/plan/*/scripts/plan-research.sh --install   # optional: headless launcher on PATH

Answer a question with empirical proof instead of source-reading alone. `/plan:research` splits the work three ways: a read-only researcher gathers facts with `file:line` citations, the main thread turns them into falsifiable hypotheses, and a proover writes runnable artifacts that try to **disprove** each one. The answer tags every claim, and the artifacts stay on disk for anyone to re-run.

## Core ideas

- **A claim about runtime behaviour gets a script, not a paragraph.** The proover calls the REAL function, query or endpoint from a throwaway file under `tmp/a/<slug>/`; a re-implementation caps the verdict at INCONCLUSIVE.
- **Bias toward disproving.** Every hypothesis gets a boundary and an adversarial input, not only the happy path. A surprising negative is the point.
- **Five tags, no inflation.** PROVEN, DISPROVED, INCONCLUSIVE, READ-ONLY (cited), ASSUMPTION (flagged). DISPROVED findings lead the answer.
- **Peers can ask too.** `plan-research.sh "<question>"` runs the same command headless with every MCP server off, prints the answer and leaves `tmp/a/<slug>/answer.md` beside the proofs. The `peer-chat` plugin's Codex side calls it when a chat claim needs a check.
- **Project tooling lives in the project.** A committed `.plan.json` names the skills to load, the container and test-runner command shapes and the read-only DB path. No profile: the agents derive what they can from the repo and say so.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| command | `/plan:research <question>` | 🔬 orchestrates researcher, hypotheses, proover, honest answer |
| agent | `plan:answer-researcher` | 📚 Sonnet, read-only, writes `tmp/a/<slug>/research.md` with cites and suggested hypotheses |
| agent | `plan:answer-proover` | 🧪 Sonnet, writes proof scripts, raw outputs and `tmp/a/<slug>/proof.md` with verdicts |
| script | `scripts/plan-research.sh` | 🤖 headless runner; `--explain`, `--install` (launcher on PATH), `--check` |

## Config

Env wins, then a committed `.plan.json` at the repo root, then the default. `plan-research.sh --explain` prints every value with its source.

| key | env | default | what |
|-----|-----|---------|------|
| `claude_command` | `PLAN_CLAUDE_COMMAND` | `claude` | the binary the headless run execs |
| `claude_args` | `PLAN_CLAUDE_ARGS` | `--permission-mode acceptEdits` | flags for the headless run; widen with `--allowedTools` when the proover must run containers |
| `artifacts_dir` | `PLAN_ARTIFACTS_DIR` | `tmp/a` | where `<slug>/` directories land, relative to the repo root |
| `timeout` | `PLAN_RESEARCH_TIMEOUT` | `1500` | seconds before the headless run is killed (needs `timeout` or `gtimeout`) |

The agents read more keys from the same file:

```json
{
  "skills": { "researcher": ["my-domain", "my-db"], "proover": ["my-testing", "my-db"] },
  "knowledge": ["docs/index.md", "docs/tribal-knowledge.md"],
  "commands": {
    "php_in_container": "docker cp <file> <svc>:/tmp/ && docker exec <svc> php /tmp/<file>",
    "run_test": "make test SERVICE=<service> PATH=<path>",
    "db_readonly": "bin/db.sh (SELECT only)",
    "http": "curl -s -o /dev/null -w '%{http_code}' <url>"
  }
}
```

## The headless run and permissions

`plan-research.sh` never bypasses Claude's permission checks. `acceptEdits` lets the subagents write their artifacts; a Bash command the project has not allow-listed is denied and the proover reports INCONCLUSIVE for that hypothesis. A project that wants proofs inside containers adds the exact tools to `claude_args` in its `.plan.json`. Codex asks for approval on every `plan-research.sh` run; the installer writes no approval rule, that decision is the user's.

## Prior art

The pipeline started life as a project command and two subagents in a private monorepo; this plugin is the neutral extraction, with the project facts moved into `.plan.json`.
