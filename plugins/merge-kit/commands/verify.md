---
description: >
  Forensic check that a merge, rebase or squash did not silently revert work that
  landed on the target after the fork point. Reads the repo map and the forge CLI
  from the project profile, runs the analysis against the fork point rather than
  the previous commit, and reports a per-file verdict with the exact lines lost.
argument-hint: <repo> <merge-commit> | <repo> <pr-number> | <repo> --in-progress [--fork <ref>] [--source <branch>]
disable-model-invocation: true
---

# `/merge-kit:verify`

Answers one question: did this merge quietly drop something the target had gained since the fork?

git resolves conflicts textually. Where two changes do not overlap line for line it merges them without asking, and where one side rewrote a region the other side had extended, the extension disappears with no conflict and no notice. The loss is invisible in the merge's own diff — it only shows against the fork point, further back than anyone looks.

Runs standalone over any historical merge, and inline as the pre-commit gate of `/merge-kit:resolve`.

## Phase 0 — Resolve the project profile (ALWAYS FIRST)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-kit.sh" --explain --repo <repo>
```

| JSON key | What it decides |
| --- | --- |
| `values.repos[<alias>]` | REPO_DIR — the repository every git call is scoped to |
| `values.forge[<alias>]` | which forge CLI turns a request number into a merge commit (Phase 1) |
| `values.work_dir` | where the report is written |
| `sources.<key>` | `profile`, `detected:<signal>` or `default` — quoted verbatim when reporting |

Exit 2 → STOP and print the script's own message; it names the markers it looked for. `values.forge` is always `detected:origin-url`, read from the repository's own `origin` remote, so it is never a stale committed field.

## Input

**`$ARGUMENTS`** — one of:

| Form | Example | Behaviour |
| --- | --- | --- |
| `<repo> <merge-commit>` | `api 8597c0ca` | Audit that commit directly |
| `<repo> <pr-number>` | `api 597` | Resolve the request's merge commit through the forge CLI, then audit it |
| `<repo> --in-progress` | `api --in-progress` | Audit the merge or rebase currently stopped in the working tree |

| Flag | When it is needed |
| --- | --- |
| `--fork <ref>` | The fork point, when git cannot recover it — a squash has one parent and records no link back to its source branch |
| `--source <branch>` | The branch that was merged, so the fork point can be recovered as its merge base |

## Variables

| Variable | Source | Description |
| --- | --- | --- |
| REPO_DIR | `values.repos[<alias>]` | local checkout being audited |
| MERGE_HASH | argument, or resolved from the request | the commit under audit |
| WORK_ID | `merge-verify-YYYYMMDD-HHmm` | one directory per run |
| WORK_DIR | `{values.work_dir}/{WORK_ID}` | inventories and the report |

## Phase 1 — Resolve the target of the audit

1. Resolve `<repo>` through Phase 0 and verify `{REPO_DIR}/.git` exists. If the checkout is missing, STOP and say so — this command reads a repository, it does not clone one.
2. Fetch first so the fork point is reachable: `git -C {REPO_DIR} fetch origin`.
3. A request number rather than a commit → resolve it with the CLI `values.forge[<alias>]` names:

   | `values.forge` | Resolve the merge commit |
   | --- | --- |
   | `gh` | `gh pr view {N} --repo {owner}/{name} --json mergeCommit,headRefName,baseRefName` |
   | `bbkt` | `bbkt prs get {workspace} {name} {N} --json` |
   | `glab` | `glab mr view {N} --output json` |
   | `null` | No CLI is known for that host. ASK the user for the merge commit hash; NEVER guess one from the log. |

   The owner and name come from `git -C {REPO_DIR} remote get-url origin`, never from a hard-coded table.

4. `mkdir -p {WORK_DIR}`.

## Phase 2 — Run the analysis

The whole comparison lives in the forensic script, so this command never re-derives it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-forensics.sh" --repo {REPO_DIR} {MERGE_HASH} [--fork {ref}] [--source {branch}]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-forensics.sh" --repo {REPO_DIR} --in-progress
```

Save the JSON to `{WORK_DIR}/forensics.json`. It answers from three references:

| Key | Meaning |
| --- | --- |
| `mode` | `merge`, `squash`, `in-progress-merge` or `in-progress-rebase` — autodetected from the repository's state |
| `fork` / `pre` / `post` | where the source branch left the target · the target just before the merge · the merged result (a commit, or the index and worktree mid-merge) |
| `target_changed` / `merge_changed` | how many files each side touched, whitespace ignored |
| `at_risk` | the intersection — files the target changed AND the merge touched |
| `full_reverts` | files whose merged content is byte-for-byte the fork's: the target's work on them is gone in full |
| `lost_lines[]` | per file, the `count` and the exact `lines` the target added and the merge dropped |
| `verdict` | `CLEAN` or `FINDINGS` — the verdict is in the JSON; exit 0 only means the analysis ran |

**Exit 2 is a usage error, never a verdict.** The one you will actually meet: `squash merge: pass --fork or --source`. A squash lands one commit with one parent and git records no link back to the source branch, so the fork point is not recoverable from the graph — guessing it would produce a confident wrong answer. Ask the user for the branch or the fork commit and re-run with `--source` or `--fork`.

`at_risk` is empty → "No overlapping files. The merge reverted nothing." Report the three references and stop; there is nothing to classify.

## Phase 3 — Classify each finding

The script reports what changed. Deciding whether a change was a loss is this command's job — read each finding before naming it:

| Verdict | Evidence |
| --- | --- |
| `REFORMATTED` | The lost lines reappear with different spacing or wrapping. `git -C {REPO_DIR} diff -w {pre} {post} -- {file}` shows nothing. |
| `MOVED` | The content exists at another path in POST. Check the merge's rename and add list before calling a full revert a deletion. |
| `REFACTORED` | The lines were replaced on purpose by the source branch — a rename, a signature change, an extracted helper. The behaviour is still there in another shape. |
| `REVERTED` | The target's additions are simply absent from POST, and nothing in the merge replaces them. This is the finding worth waking someone for. |

Quote the actual lost lines for every `REVERTED` file. A verdict with no lines under it teaches the reader to skip the next one.

## Phase 4 — Attribute the loss

For each `REVERTED` file, find who lost the work:

```bash
git -C {REPO_DIR} log --oneline --no-merges {fork}..{pre} -- {file}
```

The commits that touched the file between FORK and PRE are the changes the merge dropped. Where the forge CLI is available, map each to its request so the report names something a person can reopen.

## Phase 5 — Report

Write `{WORK_DIR}/verification-report.md` — always, even on a clean verdict:

```markdown
# Merge Verification Report

**Repo**: {REPO_DIR}
**Mode**: {mode}
**Commit**: {post}
**Window**: {fork} → {pre}
**Generated**: {NOW}

## Summary

| Verdict | Count |
| --- | --- |
| CLEAN | {N} |
| REFORMATTED | {N} |
| MOVED | {N} |
| REFACTORED | {N} |
| **REVERTED** | **{N}** |

## Reverted files

| File | Lost from | Lines lost | Sample |
| --- | --- | --- | --- |
| {path} | {commit or request} | {N} | `{first lost line}` |

## At-risk files reviewed

| File | Verdict | Why |
| --- | --- | --- |
```

Then to the user:

- The verdict counts, and the three references the analysis used.
- Every `REVERTED` file with its lost lines and where they came from.
- Zero reversions → "The merge is clean. No silent reversions detected." Say it plainly; a clean answer is the common case and it has to be cheap.
- Reversions found → the next step is to re-apply the lost work on top of the current target, not to re-run the merge.

## Guardrails

- READ-ONLY. NEVER write to a remote, never commit, never modify the working tree. The only write is the report under `{WORK_DIR}`.
- Phase 0 first, and its answer is authoritative. NEVER hard-code a repository path or a forge CLI the profile could have supplied.
- MUST pass `--repo {REPO_DIR}` on every forensic call — a forensic tool that reads whichever repository the shell happens to sit in is worse than none.
- MUST use `git -C {REPO_DIR}` — never `cd {REPO_DIR} && git`, because the `cd` persists into later calls.
- NEVER call a squash's fork point yourself when the script refused to. Ask for `--fork` or `--source`.
- MUST save the report even when nothing was found — a clean audit is evidence too.
- A window longer than six months or wider than 200 commits → warn about the analysis time before starting.
