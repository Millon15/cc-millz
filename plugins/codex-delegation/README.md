# 🤖 codex-delegation

    /plugin install codex-delegation@cc-millz

Uses the Codex CLI as a second-tier workforce: Claude remains the orchestrator and taste owner, while Codex handles bulk work, second opinions, and independent verification.

⚠️ **Depends on** the `codex` CLI and the official [codex-plugin-cc plugin](https://github.com/openai/codex-plugin-cc) (`/plugin install codex@openai-codex`, then `/codex:setup`).

Official Codex plugin implementations always take precedence: reviews, implementation handoffs, and diagnosis route through the official `/codex:review`, `/codex:adversarial-review`, and `codex:codex-rescue`. This plugin only adds the lanes the official one does not cover, and it is Claude-side only: Codex itself never loads it.

## Core ideas

- **Tracked jobs.** Every Codex run in these lanes goes through one adapter, `scripts/codex-job.sh`, over the official companion. It writes the launch intent before spawning, returns a handle at once, and keeps one record per invocation. Retrying `start` with the same invocation id returns the existing job instead of launching a second one.
- **Launch once.** After launch, a job is collected, cancelled or reported `uncertain`. The prompt is never sent a second time on any backend.
- **Separate records.** Each record keeps three fields apart: lifecycle (`running`, `completed`, `uncertain`, …), the task's verdict (`pass`, `fail`, `blocked`, `unknown`), and the parent's disposition (`pending`, `accepted`, `rejected`). A missing or malformed report gives the verdict `unknown`. The adapter never rebuilds a verdict from prose.
- **Narrowest sandbox.** A job runs `read-only`, or `workspace-write` when it must write. An operation the sandbox refuses comes back as `blocked`, and the sandbox is never widened as a fallback.
- **Codex output is evidence, not authority.** Claude checks each claim's receipt (`path:line`, or command, expected, observed and exit) before relaying it or accepting a job.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `codex-delegation:codex-delegate` | 🧭 Routing brain: maps intent to the official command or agent, a peer-chat Codex peer, or an adapter lane; carries the probe-with-reason preflight and the verification stance |
| skill | `codex-delegation:codex-workflow-fanout` | 🔀 gpt workers inside Workflow/Agent fan-outs: start, hand back the handle, collect, dispose; the brief and report contract; worktree isolation for writes |
| skill | `codex-delegation:codex-computer-use` | 🖥️ Independent UI/runtime verification: declared capabilities choose the sandbox, refused operations come back `blocked` |
| agent | `codex-workflow-worker` | 📦 Spawnable thin wrapper: starts one job and returns its handle, or makes one bounded collect call |
| script | `scripts/codex-job.sh` | ⚙️ The adapter: `probe`, `start`, `status`, `collect`, `cancel`, `dispose`; `--explain` prints what it resolved |

## Adapter settings

The adapter has no project profile. It finds the newest installed official companion, version 1.0.6 or a later 1.x. Two environment variables override it, and `--explain` names the source of each value:

| Variable | Effect | Default |
|----------|--------|---------|
| `CODEX_JOB_COMPANION` | path to the `codex-companion.mjs` to use | the newest supported installed copy |
| `CODEX_JOB_CALL_TIMEOUT_SECONDS` | upper bound on one companion call, 1–600; it never limits how long a job runs | 60 |

Exit codes: `0` ok, `1` internal error, `2` refused, `3` unavailable before launch, `4` still running at the wait budget, `5` uncertain.

The run dir holds the records the parent trusts, so a job must never be able to write it. Every verb re-resolves the companion and refuses a record that names another one. A `workspace-write` start refuses a run dir, adapter or companion that lies under the job's `--cwd`, `/tmp` or `$TMPDIR`, which are Codex's default writable roots. Those checks do not see a writable root you add in Codex's own config, so such a root must never contain the run dir or the adapter and companion scripts. Nor may any run dir, a read-only job's included, sit inside another job's worktree: a record is trusted only while no sandbox can write it.

---

Part of [cc-millz](../../README.md).
