---
name: concise-writing
description: >
  The compression procedure — how to cut correct-but-long prose down to its load-bearing facts.
  The fact test, merge-repeats-upward, and a hard stop condition.
  Style floor for code comments, commit messages, PR descriptions and team-visible sends.
when_to_use: >
  Load BEFORE writing any docblock, code comment, commit message, PR description, Slack/Jira
  body, or ticket comment. Also on: shorten, tighten, trim, condense, "make it concise",
  "too verbose", or reviewing text that reads bloated.
---

# Concise Writing

Cut to the load-bearing facts. This skill is about REMOVING, never rewording.

## The fact test — the whole procedure

For each sentence: **does the reader lose a FACT if it goes?**

A fact is something the reader cannot recover from the code, the names, or the surrounding
context. Everything else is filler with good posture:

| Not a fact | Looks like | Do |
| --- | --- | --- |
| Derivation | the arithmetic that produced a number | state the number and the conclusion |
| Motivation | why the problem matters | delete — the ticket carries it |
| Restatement | what the next line plainly does | delete |
| Reassurance | "this is safe because…" | delete unless it names a real constraint |

Keep the fact, kill the derivation:

- BEFORE (13 lines): "…the gate compares against `stamp`, written when the refresh FINISHES. A job
  queued by run N is consumed up to `--spread` seconds late, so the age at run N+k is
  `k*interval + delay(N+k) - delay(N) - runtime`, which is BELOW `k*interval`. To skip k-1 runs and
  fire on the kth, a value must sit inside…"
- AFTER (1 line): "…which is why two hours is 5400, not 7200."

## Annotations are not prose — never cut them

`@throws`, `@param`, `@return`, `@var`, `@deprecated`, `@template` state facts the signature cannot.
They are the one part of a docblock this skill NEVER touches, and a missing one is a defect:

- **`@throws` on every method that can throw** — including a throw raised by a private helper it calls.
  Without it the caller cannot know a `try/catch` is owed, and the IDE cannot warn them.
- **`@param` / `@return` only where the type hint is not the whole truth** — generics
  (`array<int, RefreshTarget>`, `list<string>`), a shape, a unit, a nullable's meaning. A bare
  `@param int $id` restating `int $id` IS restatement — cut that one.
- One clause each, on the tag line. The tag says WHAT, never WHY.

The 10% comment ceiling in `code-style` excludes annotations for exactly this reason: adding a
`@throws` never costs you budget, so there is no excuse to skip it.

## Three more moves

1. **Merge repeats upward.** N siblings each re-explaining one mechanism → ONE parent explanation
   + N pointers. This is SLAP for prose, and it is the biggest single win.
2. **Front-load.** The first five words carry the idea. A reader who stops there still got it.
3. **One idea per sentence.** Two ideas joined by "and" or ", so" are two sentences — or one plus a cut.

## Stop condition

Cut until removing one more word would remove a fact. Then STOP — do not reword for polish.

## Write long, then cut

Draft the full reasoning first, compress second. Compression is an edit of correct text, never a
constraint on thinking. Just never ship the draft.

## Scope

| Surface | Applies | On top of this |
| --- | --- | --- |
| Code comments + docblocks | YES, prose only | `code-style` — docblock = 1 sentence; a 2nd means extract a method. Annotations exempt (above) |
| Commit message body | YES | the WHY evicted from source lands here |
| PR description | YES | ditto |
| Slack / Jira bodies | YES | `outbound-comms` adds nested-list shape + clickable links |
| README, public docs, postmortems, customer comms | NO | clarity over brevity — full prose |
