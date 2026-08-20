---
description: >
  Resolve the conflicts of a merge or a rebase in any repository. Reads the repo
  map, the forge CLI and the test command from the project profile, auto-resolves
  the hunks a stated fact settles, walks the ambiguous ones one at a time, and
  proves before committing that nothing on the target was silently reverted.
argument-hint: <repo> <pr-number> | <repo> local <feature> <target> [merge|rebase] [--strict]
disable-model-invocation: true
---

# `/merge-kit:resolve`

Interactive conflict resolution for a pull request's branch, or for a local feature branch syncing with its target.

> **AUTO is the default.** TRIVIAL and OBVIOUS hunks are resolved without asking (4b); only genuinely AMBIGUOUS ones stop for a decision (4c). Announce up front how many will auto-resolve and how many will be walked. `--strict` walks every conflict — TRIVIAL still auto-resolves.

**Prior art.** The three-tier classification below owes its shape to `mattpocock-skills:resolving-merge-conflicts`, which argues that a conflict is resolved by understanding both intents rather than by picking a side. Load that skill when it is in the session's skill list and let it inform the walk; this command adds the profile resolution, the forensic net and the auto-resolve tiering around it.

## Phase 0 — Resolve the project profile (ALWAYS FIRST)

Nothing below is derived from prose. Run the entry script and consume its JSON:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-kit.sh" --explain --repo <repo>
```

| JSON key | What it decides |
| --- | --- |
| `values.repos[<alias>]` | REPO_DIR — the path every `git -C` call uses |
| `values.forge[<alias>]` | which forge CLI fetches the pull request's branches (Phase 1) |
| `values.test_command[<alias>]` | the suite Phase 5 runs |
| `values.work_dir` | where the work directory is created |
| `sources.<key>` | `profile`, `detected:<signal>` or `default` — quoted verbatim when reporting |

- Exit 2 means the profile is unreadable or there is nothing to detect. STOP and print the script's own message; it names the markers it looked for. NEVER continue on a guess.
- `values.forge` is ALWAYS `detected:origin-url` — it is read from each repo's own `origin` remote, never from a committed field, so a repo that moved between forges is right on this run.
- `test_command` is present only under `--repo`, because the ladder lands on a different rung per repository.

Announce one resolution line before touching git:

```
profile: {profile_file|none} · repo {alias} → {REPO_DIR} · forge {cli} ({sources.forge}) · tests `{test_command}` ({sources.test_command})
```

## Input

**`$ARGUMENTS`** — one of:

| Form | Example | Behaviour |
| --- | --- | --- |
| `<repo> <pr-number>` | `api 583` | PR mode — fetch SOURCE and TARGET from the forge |
| `<repo> local <feature> <target> [merge\|rebase]` | `api local feat-x main merge` | LOCAL mode — no pull request; strategy defaults to `merge` |

`<repo>` is a profile alias or the path it maps to; both are accepted by `--repo`.

| Flag | Effect |
| --- | --- |
| `--strict` | Walk EVERY conflict one at a time. TRIVIAL still auto-resolves; OBVIOUS hunks are walked instead of applied. For high-stakes repositories or a full manual review. |

## Variables

| Variable | Source | Description |
| --- | --- | --- |
| REPO_DIR | `values.repos[<alias>]` | local checkout the whole run operates on |
| SOURCE | forge metadata (PR mode) or `<feature>` (local mode) | the branch carrying the changes |
| TARGET | forge metadata (PR mode) or `<target>` (local mode) | the branch receiving them |
| WORK_ID | `merge-resolve-YYYYMMDD-HHmm` | one directory per run |
| WORK_DIR | `{values.work_dir}/{WORK_ID}` | logs, inventories, the resolution summary |

## Phase 1 — Parse and validate

1. Parse `$ARGUMENTS` into `<repo>`, the mode and the flags.
2. Resolve `<repo>` through Phase 0. Verify `{REPO_DIR}/.git` exists — if not, STOP: "Repo not checked out at `{REPO_DIR}`. Clone it first."
3. **PR mode** — fetch the pull request's branches with the CLI `values.forge[<alias>]` named:

   | `values.forge` | Fetch |
   | --- | --- |
   | `gh` | `gh pr view {PR} --repo {owner}/{name} --json headRefName,baseRefName,title` |
   | `bbkt` | `bbkt prs get {workspace} {name} {PR} --json` |
   | `glab` | `glab mr view {PR} --output json` |
   | `null` | No CLI is known for that host. ASK the user for the source and target branch names, or tell them to use LOCAL mode. NEVER guess a branch. |

   The owner and name come from the repository's own `origin` URL — read it with `git -C {REPO_DIR} remote get-url origin`, never from a hard-coded table.

4. **LOCAL mode** — SOURCE and TARGET come straight from the arguments; skip the fetch entirely.
5. Create the work directory: `mkdir -p {WORK_DIR}`.
6. Write the branch's purpose to `{WORK_DIR}/branch-purpose.md` — one line on what SOURCE is for, which sets the default direction for TRIVIAL hunks. If it is unclear, ASK before Phase 4 starts.

## Phase 2 — Prepare branches

```bash
git -C {REPO_DIR} fetch origin {SOURCE} {TARGET}
git -C {REPO_DIR} checkout {SOURCE}
git -C {REPO_DIR} pull origin {SOURCE}
```

In LOCAL mode skip the fetch-and-pull churn — the caller already left you on `{SOURCE}` with `{TARGET}` up to date locally. Confirm the current branch is `{SOURCE}` and move on.

Report the divergence:

```bash
git -C {REPO_DIR} log --oneline {TARGET}..{SOURCE} | wc -l   # source-only commits
git -C {REPO_DIR} log --oneline {SOURCE}..{TARGET} | wc -l   # target-only commits
```

No divergence → "No conflicts possible, the branches are fast-forwardable." and stop.

## Phase 3 — Bring TARGET into SOURCE

Always merge TARGET into SOURCE. NEVER check out or modify TARGET.

```bash
git -C {REPO_DIR} merge origin/{TARGET} --no-commit --no-ff     # PR mode
git -C {REPO_DIR} merge {TARGET} --no-commit --no-ff            # LOCAL mode
```

Under the `rebase` strategy the caller's `git rebase {TARGET}` has already stopped at a conflicting step: resolve that step's files through the Phase 4 walk, then `git -C {REPO_DIR} rebase --continue`, and repeat per stopped step.

Clean merge, no conflicts → skip to Phase 5.

With conflicts:

```bash
git -C {REPO_DIR} diff --name-only --diff-filter=U > {WORK_DIR}/conflicted-files.txt
```

## Phase 3.5 — Silent-revert audit BEFORE the walk (MANDATORY)

`git merge` auto-resolves every file whose changed regions do not textually overlap. Where one side rewrote a region the other side had extended, the extension can vanish with no conflict and no notice — and nothing in the merge's own diff shows it. Ask the forensic script, which compares against the fork point rather than against the previous commit:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-forensics.sh" --repo {REPO_DIR} --in-progress
```

It autodetects merge versus rebase from the repository's own state and reads POST from the index and worktree, so it works mid-conflict, before anything is committed. Consume its JSON:

| Key | Meaning |
| --- | --- |
| `verdict` | `CLEAN` or `FINDINGS` — the verdict is in the JSON, never in the exit code |
| `at_risk` | files the target changed since the fork AND this merge touched |
| `full_reverts` | files whose merged content is back to the fork's, in full |
| `lost_lines[]` | per file: `count` and the exact `lines` the target added and the merge dropped |
| `fork` / `pre` / `post` | the three references the analysis used, for the record |

Save the output to `{WORK_DIR}/audit-pre-walk.json`. `FINDINGS` → every file in `full_reverts` and `lost_lines` is a SILENT-REVERT candidate: walk it through 4c BEFORE the declared conflicts, quoting the lost lines. Exit 2 is a usage error in the invocation, not a verdict — fix the call.

## Phase 4 — Resolve (tiered auto-resolve + ambiguity walk)

Process the declared conflicts AND the SILENT-REVERT candidates in one loop. Per hunk: classify (4a), auto-resolve the settled ones (4b), walk the rest (4c).

> **Why auto-resolve is safe here**: the net — the Phase 3.5 audit, the Phase 5 full suite, the Phase 5.5 forensic verify — is what catches a wrong auto-resolution. Auto-resolve is licensed ONLY because all three run unconditionally. NEVER skip or weaken one to move faster.

### 4a. Classification — three tiers

| Tier | Definition | Action |
| --- | --- | --- |
| **TRIVIAL** | Pure formatting noise: whitespace, blank lines, indentation, line endings, import-block ordering, formatter alignment. `diff --ignore-all-space` of the two sides is empty. | AUTO (4b) |
| **OBVIOUS** | Exactly ONE correct outcome, nameable from a FACT rather than guessed intent: (a) additive UNION — both sides add non-overlapping content at the same spot (keep both, adding the structural seam the concatenation needs); (b) SUPERSET — one side strictly contains the other, or one is a stale older draft, so the richer or newer one wins; (c) EVIDENCE-determined — an external fact (a referenced key, symbol or file already exists on TARGET, or was removed there) makes one side working and the other broken; (d) mechanical normalisation to the file's own convention. | AUTO (4b), log the fact |
| **AMBIGUOUS** | Everything else. Both sides changed the same region to different behaviour with no fact naming a winner; OR the resolution drops behaviour the suite will not catch; OR it is a high-blast-radius revert or a large deletion of TARGET content, even where it looks intended. **If you cannot state the single correct outcome as a fact, it is AMBIGUOUS.** | WALK (4c) |

**Boundary discipline.** OBVIOUS demands a stated fact — "the two blocks are independent test cases", "TARGET already carries this file from merged request #12", "the config defines `apiKey` and has no `agentId`, so that side is broken". "Probably", "seems fine" and "both likely want it" are not facts: that is AMBIGUOUS, walk it. Under `--strict`, OBVIOUS collapses into AMBIGUOUS.

**OBVIOUS — auto-resolve, log the fact:**

- Both sides add different, non-overlapping cases or fields at the same spot → UNION, plus the closing seam the concatenation needs. Fact: "the two blocks are independent."
- add/add where TARGET carries the richer or newer version → take TARGET. Fact: "TARGET's is a superset, from merged request #12."
- SOURCE reads `&a={{agentId}}` where TARGET reads `&k={{apiKey}}`, and the environment file defines `apiKey` and no `agentId` → take the working side. Fact: "`agentId` is undefined, so that side is broken."
- An import-block reorder plus one added import → take the superset. Fact: "the reorder is noise; the added import is additive."

**Still AMBIGUOUS — walk:**

- Both sides changed the same logic to different behaviour and no fact names a winner.
- A resolution that removes TARGET behaviour the suite does not cover.
- A whole-file revert or a large deletion of TARGET content — walk it even where the diff looks intended. That is exactly where a "clean" auto-merge hides a silent revert.

### 4b. Auto-resolution (TRIVIAL + OBVIOUS)

1. Apply the resolution — TRIVIAL: the default direction from Phase 1 step 6. OBVIOUS: the fact-determined outcome.
2. Apply the structural seam (a closing bracket, a comma, a terminator) in the same step where the concatenation needs one to stay valid.
3. Append to `{WORK_DIR}/auto-resolved.md`: `AUTO {TRIVIAL|OBVIOUS}: {file} — {outcome} ({the one-line fact})`.
4. `git -C {REPO_DIR} add {file}`.

Every OBVIOUS call is echoed in the 4d summary so the user can audit and object before the commit. When resolving a rebase, remember the inversion: `--ours` is the branch being rebased ONTO (TARGET), `--theirs` is the commit being replayed (SOURCE).

### 4c. Interactive resolution (AMBIGUOUS) — one at a time

**IRON RULE**: present EVERY AMBIGUOUS conflict ONE AT A TIME. NEVER batch, skip, summarise or mechanically merge several together. Finish one (Step 1 → Step 7) before starting the next; each is a separate user-visible round trip.

**Self-check before applying any ambiguous resolution**: did the user say HEAD, TARGET or merge for THIS conflict in their last message? If not, STOP and ask. Past approvals do not transfer.

**Step 1 — Header.** Print `## AMBIGUOUS #{n}: {file}:{line} — {short description}`.

**Step 2 — Both versions, annotated.** Show each side as its own block, with the surrounding context and inline `// ←` markers on the lines that differ. Annotations are short (under 40 characters) and never sit on unchanged context.

**HEAD ({SOURCE}):**

```
retry_limit = 3                       // ← literal kept (HEAD)
send(payload)
```

**TARGET ({TARGET}):**

```
retry_limit = DEFAULT_RETRY_LIMIT     // ← replaced with the shared constant (TARGET)
send(payload, timeout)                // ← NEW argument (TARGET only)
```

**Step 3 — Differences table.**

| Aspect | HEAD | TARGET |
| --- | --- | --- |
| {what changed} | {HEAD behaviour} | {TARGET behaviour} |

**Step 4 — Recommendation.** Which side to take, or how to combine both, and why — one or two sentences.

**Step 5 — Wait.** Ask _"Take HEAD, TARGET, or merge both?"_ and WAIT. NEVER auto-apply.

**Step 6 — Apply and confirm.** Apply, `git -C {REPO_DIR} add {file}`, confirm the file is clean.

**Step 7 — Inter-conflict checkpoint (MANDATORY).**

1. Append to `{WORK_DIR}/walkthrough.md`:

   ```
   ## Conflict #{n}: {file}
   - decision: {HEAD|TARGET|merged}
   - rationale: {one line}
   - applied at: {timestamp}
   ```

2. Do NOT open conflict N+1 in the same tool-call sequence as Step 6 of conflict N. Its edits come AFTER a user message acknowledging N.
3. If the user's last message did not address N+1 specifically, present its Step 1 and STOP — even where it looks like the same pattern as N.

### 4d. Resolution summary

```markdown
## Conflict Resolution Summary

| File | Tier | Resolution | Fact / decision |
| --- | --- | --- | --- |
| src/pricing | TRIVIAL | Auto: TARGET | whitespace only |
| tests/pricing-cases | OBVIOUS | Auto: UNION (both) | independent test blocks |
| docs/api.http | OBVIOUS | Auto: TARGET | TARGET superset (merged request #12) |
| src/checkout | AMBIGUOUS | User chose: merged | divergent logic, no fact-winner |
| README.md | AMBIGUOUS | User chose: keep TARGET | high-blast-radius revert |

Total: {N} files, {T} auto (TRIVIAL+OBVIOUS), {W} walked (AMBIGUOUS), {R} silent-revert restored
```

Echo the full `auto-resolved.md` list under an **Auto-resolved (review)** heading so every OBVIOUS call is auditable, and save the table to `{WORK_DIR}/resolution-summary.md`.

## Phase 5 — Run the suite

Run `values.test_command[<alias>]` from Phase 0, from `{REPO_DIR}`, and report the result together with `sources.test_command` so the user knows whether the command was declared or detected:

```
tests: `{test_command}` ({sources.test_command})
```

- Run the FULL suite the profile names, never a narrow subset of the touched files. In AUTO mode it is the primary net that catches a wrong OBVIOUS resolution — a dropped case, a missing seam, a lost argument.
- `test_command` is `null` (source `default`) → nothing was detectable. ASK the user for the command to run, and tell them a `test_commands` entry in `.merge-kit.json` makes the answer permanent. NEVER invent one, and NEVER skip the phase silently.
- A project whose merges need more than unit tests — an end-to-end suite, a scenario runner — points its `test_commands` entry at that instead. This command knows one runner per repository, and it is the profile's.

Tests fail → show the failures, then ask _"Fix the failures before committing, or commit with known failures?"_ If fixing: read the failure, apply, re-run.

## Phase 5.5 — Forensic verification BEFORE the commit (MANDATORY)

Re-run the forensic script over the resolved state, still in progress:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-forensics.sh" --repo {REPO_DIR} --in-progress
```

Save it to `{WORK_DIR}/audit-pre-commit.json`. This is a different question from Phase 3.5: that one asked what git's auto-merge dropped, this one asks what survived the whole run — including a resolution the user chose that itself dropped a line.

`verdict` is `FINDINGS` → treat each entry as a SILENT-REVERT walk (4c), resolve it, and re-run until the verdict is `CLEAN`. Only a `CLEAN` verdict opens Phase 6.

## Phase 6 — Commit and push

Use `git merge --continue`. NEVER `git commit -m` for a merge commit.

1. Read the prepared message: `cat {REPO_DIR}/.git/MERGE_MSG` (a separate call — no command substitution).
2. Append the resolution block:

   ```
   {original MERGE_MSG content}

   Conflicts resolved ({N} files, {T} auto, {S} user):
   - {file} — {TRIVIAL|OBVIOUS|AMBIGUOUS}: {one-line resolution}
   - {file} — {TRIVIAL|OBVIOUS|AMBIGUOUS}: {one-line resolution}
   ```

3. Show the summary table for the record and proceed IMMEDIATELY — the merge message is auto-generated and always acceptable. NEVER stop to ask for approval of the message text.
4. Write the message back to `{REPO_DIR}/.git/MERGE_MSG` and commit without opening an editor:

   ```bash
   GIT_EDITOR=true git -C {REPO_DIR} merge --continue
   ```

   Under the rebase strategy: `GIT_EDITOR=true git -C {REPO_DIR} rebase --continue`.

5. PR mode: ask _"Push to origin/{SOURCE}?"_ — the push is an outward action and always gates. On yes: `git -C {REPO_DIR} push origin {SOURCE}`.
6. LOCAL mode: NEVER push. The caller owns the push policy, and a rebased branch needs a deliberate force-push by the user.

## Guardrails

- NEVER check out or modify TARGET — all work happens on SOURCE.
- Phase 0 comes first and its answer is authoritative. NEVER hard-code a repository path, a forge CLI or a test command that the profile could have supplied.
- AUTO-RESOLVE only TRIVIAL and OBVIOUS hunks, each licensed by a STATED FACT. Walk every AMBIGUOUS one, one at a time. Cannot name the outcome as a fact → it is AMBIGUOUS.
- Log every OBVIOUS auto-resolution with its fact, and echo the full list in 4d for audit.
- The net is NON-NEGOTIABLE: Phase 3.5 audit before the walk, Phase 5 full suite, Phase 5.5 forensic verify before the commit. NEVER skip or weaken one, not even for a merge that looks clean.
- HIGH-BLAST-RADIUS reverts — a whole-file deletion, a large removal of TARGET content — are ALWAYS AMBIGUOUS.
- NEVER force-push, NEVER delete a branch.
- MUST use `git -C {REPO_DIR}` — never `cd {REPO_DIR} && git`, because the `cd` persists into later calls.
- More than 50 conflicted files → warn and ask whether to proceed or abort.
- "Suggest" and "recommend" belong to Step 4 of a walk. Classification and the forensic phases report facts; they do not advise.
