---
name: codex-computer-use
description: Ask Codex CLI to run local runtime verification as an independent agent, such as browser automation, simulators, app launching, screenshots or runtime inspection. Use when the user wants Codex/GPT to test a flow, verify UI behavior, inspect a running app, or capture proof of implemented behavior.
---
# Codex Computer Use

An independent agent checks runtime behaviour Claude built. Not for code reading, typecheck, lint or tests Claude can
run itself. Launching apps, simulators and browsers to verify the requested work needs no question; ask first only
when the run could disrupt the user's environment (closing their apps, changing system settings, acting on real
accounts or data).

## Capabilities pick the sandbox

The brief DECLARES what the check needs; the job runs in the narrowest sandbox that covers it:

| The check needs | Sandbox |
| --- | --- |
| reading the repo, running read-only commands | `read-only` |
| writing screenshots, logs or other artifacts, or edits the user allowed | `workspace-write`, `--cwd` a worktree of its own, artifacts under its `tmp/` |

An operation the sandbox or the host refuses (a GUI it cannot reach, the network, a path outside the workspace) comes
back in the report's `blocked[]` with the operation and the reason, and the verdict is `blocked`. Report it to the
user. The sandbox and the approval policy are never widened, as a retry or as a fallback.

## Steps

1. Probe under the sandbox the check needs (`codex-delegation:codex-delegate` § Availability).
2. Brief file: the exact behaviour to verify, platform and app type, launch commands, seed data and fixtures,
   whether source edits are allowed (default none), the declared capabilities, where artifacts go (`<worktree>/tmp/<slug>/`),
   and the closing report contract from `codex-delegation:codex-workflow-fanout` § The brief. Each runtime claim
   carries command, expected, observed, exit and evidence path.
3. Start, then collect:

```bash
git -C <repo> worktree add <repo>/tmp/codex-worktrees/<slug> HEAD
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-job.sh" start --run-dir <repo>/tmp/codex-runs/<slug> \
  --invocation-id <slug>-verify --cwd <repo>/tmp/codex-worktrees/<slug> --prompt-file <brief> --sandbox workspace-write
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-job.sh" collect --run-dir <repo>/tmp/codex-runs/<slug> \
  --invocation-id <slug>-verify --wait-seconds 150
```

   The run dir stays in the main checkout, out of the job's writable worktree, so Codex cannot touch the record.
   Exit 4 means still running: collect again (the main thread may run it in the background and wait for the
   notification). A read-only check needs no worktree: `--cwd <repo> --sandbox read-only`.
4. Read the record and the report: verdict, each runtime claim's evidence path, `blocked[]`. Summarize pass, fail or
   blocked with the screenshot paths, then `dispose` the record.
