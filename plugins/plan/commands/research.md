---
description: >
  Answer a question with empirical proof. Dispatches answer-researcher (facts with
  file:line citations), drafts falsifiable hypotheses in the main thread, then dispatches
  answer-proover (runnable artifacts under tmp/a/<slug>/ that try to DISPROVE each claim).
  The answer tags every claim PROVEN, DISPROVED, INCONCLUSIVE, READ-ONLY or ASSUMPTION and
  never inflates confidence. Use for "is it true that", "does X happen when Y", "prove it",
  or whenever a design argument rests on a claim about runtime behaviour.
argument-hint: <question or claim to prove>
allowed-tools: >-
  Read, Bash(rg:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*),
  Bash(git branch:*), Bash(git status:*), Bash(ls:*), Bash(wc:*), Bash(head:*),
  Bash(tail:*), Bash(cat:*), Bash(mkdir:*), Bash(date:*), Bash(jq:*), Write, Agent
model: opus
---
Answer the user's question: $ARGUMENTS

## Mode: answer-only, with empirical proof

Pure orchestration. Two subagents own the actual work; their `.md` files are their system
prompts, so do not repeat their instructions here:

- `plan:answer-researcher` (Phase 1, facts with citations, read-only)
- `plan:answer-proover` (Phase 3, runnable artifacts, writes only under `tmp/a/<slug>/`)

This command sequences them and composes the answer.

## Phase 0: setup

1. Pick `<slug>`: short kebab-case (30 chars or fewer) from the question.
2. `Bash: mkdir -p tmp/a/<slug>` (the profile may move the root, see step 3).
3. If a committed `.plan.json` exists at the repo root, read it once and pass its path to both
   subagents as `profile_path`. It names the project's skills to load, the command shapes for
   running code in a container, the test runner and the read-only DB path, and the local
   knowledge indexes. No profile means the subagents fall back to what the repository itself
   shows (a task runner, a docker compose file, a test directory).
4. A caller may pass `slug=<name>` in the arguments to pin the directory; honour it.

## Phase 1: dispatch the researcher

```
Agent(subagent_type="plan:answer-researcher", prompt="""
question: <verbatim user question>
slug: <slug>
profile_path: .plan.json        # only when it exists
branch: <current-branch>        # optional
pr_url: <if the user mentioned one>
ticket: <if the user mentioned one>
""")
```

Wait for the `RESEARCH_DONE` line. Read `tmp/a/<slug>/research.md`.

## Phase 2: hypothesise (main thread)

Pick 1 to 5 **falsifiable** claims from the researcher's "Suggested Hypotheses" section.
Reject any claim you are certain of from source-reading alone; those go straight to Phase 4
with citations and no proof run.

Write `tmp/a/<slug>/hypotheses.md`:

```
# Hypotheses for: <one-line summary>

## Hypothesis 1
**Claim:** <falsifiable statement>
**Why it matters:** <how the answer depends on this>
**Suggested approach:** <hint: standalone script / unit test / SQL / HTTP call>

## Hypothesis 2
...
```

If nothing is worth proving, write the file with one line, `NO_HYPOTHESES: research
sufficient`, and skip Phase 3.

## Phase 3: dispatch the proover

```
Agent(subagent_type="plan:answer-proover", prompt="""
slug: <slug>
hypotheses_path: tmp/a/<slug>/hypotheses.md
profile_path: .plan.json        # only when it exists
""")
```

Wait for the `PROOF_DONE` line. Read `tmp/a/<slug>/proof.md`.

## Phase 4: compose the honest answer (main thread)

Tag every claim in the final answer with exactly one of:

| Tag | When |
| --- | --- |
| **PROVEN** | the proover ran an artifact and the output matched |
| **DISPROVED** | the proover ran an artifact and the output contradicted the claim |
| **INCONCLUSIVE** | the proover tried and could not verify (production-only data, missing fixture) |
| **READ-ONLY** | source-reading alone, cite `file:line` |
| **ASSUMPTION** | inferred, not verified, flagged as such |

MUST: lead with DISPROVED findings, cite every proof artifact path so the user can re-run it,
pass the proover's caveats through verbatim, trust proof over research when they conflict.

MUST NOT: edit or write outside `tmp/a/<slug>/`, run mutating Bash, inflate confidence,
suggest an implementation unless the user asks "how would I fix this", redo subagent work in
the main thread.

Lead with the verdict in one sentence, then the evidence with tags, then the caveats. No
preamble.

## Guardrails

- MUST use the `Agent` tool for Phases 1 and 3. Inlining research or proof in the main thread
  defeats the context split and the cost split.
- NEVER delete `tmp/a/<slug>/` after answering; the artifacts are the record, and a peer or a
  later session reads them.
- Trivial lookups (a single search, no claim to prove) bypass both subagents; say so up front
  (`simple lookup, skipped the research pipeline`).
- When `plan-research.sh` invoked this command headless, the last block of the answer MUST
  list the artifact paths one per line under a `## Artifacts` heading, so the caller can find
  them without parsing prose.
