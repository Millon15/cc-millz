---
name: codex-computer-use
description: Ask Codex CLI to run local verification that needs computer use — browser automation, simulators, app launching, screenshots, independent runtime inspection. Use when the user wants Codex/GPT to test a flow, verify UI behavior, inspect a running app, or capture proof of implemented behavior.
---
# Codex Computer Use

Gap openai-codex plugin not cover: GUI/runtime verification by independent agent.

NOT for code reading, typecheck, lint, tests Claude run directly. Launch apps/simulators/browsers to verify requested work = fine without asking. Ask first only if run could disrupt user environment (close user apps, change system settings, act on real accounts/data).

## Workflow

1. Create artifact dir (repo `tmp/codex-runs/<slug>/` inside project, else system temp).
2. Self-contained prompt: repo path, exact flow, constraints, artifact dir, report format.
3. Run non-interactive:

```bash
codex exec -C <repo> --add-dir <artifact-dir> -s danger-full-access -o <artifact-dir>/report.md "<prompt>"
```

- `-s danger-full-access` ONLY for GUI automation, simulators, app launch, screenshots, outside-repo access. Non-GUI repo-only checks → `-s workspace-write`.
- `--skip-git-repo-check` when cwd not git repo.
- Long flows: explicit Bash timeout or background + poll report file.

4. Read report, reference screenshot paths, summarize pass/fail/blocked for user.

## Prompt MUST tell Codex

- Exact behavior to verify; platform/app type (web, iOS, Electron, CLI, desktop).
- Launch commands, test credentials, seed data, deep links, fixtures.
- Source edits allowed? (default: NO edits).
- Where save screenshots, logs, final report.
- Return contract: pass | fail | blocked + steps performed + observed behavior + screenshot paths + actionable feedback.

Prompt must stand alone — Codex see none of Claude conversation.