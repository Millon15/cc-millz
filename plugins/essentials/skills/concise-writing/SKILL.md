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

## Annotations — the cut rule splits them in two

The test is the same fact test: **can the reader recover this from the signature?** Modern type
systems (PHP 7.2+ typed params, return types, typed properties) recover most of it. What they cannot
express is where annotations earn their keep.

**DELETE — restatement of the signature:**

- `@param int $id` above `int $id`. `@return void` above `: void`. `@var string` above `string $name`.
- The type system already says it, so the tag says nothing. Cut the tag; cut the whole docblock if
  that is all it held.

**ADD, FIX WHEN STALE, NEVER DELETE — facts no type can carry:**

| Tag | Why the signature cannot say it |
| --- | --- |
| `@throws` | PHP has no checked exceptions. Without it the caller cannot know a `try/catch` is owed and the IDE cannot warn them. Declare it on every method that can throw — **including a throw raised by a private helper it calls**. |
| `@deprecated` | Names the replacement and the removal horizon. |
| `@template` / `@extends` / `@implements` | Generics the language has no syntax for. |
| PHPStan / Psalm shapes | `array<int, RefreshTarget>`, `list<string>`, `array{id: int, name: string}`, `non-empty-string`. A bare `array` is not a type. |
| `@param` / `@return` carrying more than the type | a unit, a range, what `null` means, which of two array shapes. |

These are code, not prose — a static analyser reads them. They never count against the 10% comment
ceiling in `code-style`, so skipping one buys you nothing. A missing `@throws` or a stale generic is
a defect; deleting one to "be concise" is the opposite of this skill.

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
| Code comments + docblocks | YES, prose only | `code-style` — docblock = 1 sentence; a 2nd means extract a method. Annotations follow the two-bucket rule above, not the fact test |
| Commit message body | YES | the WHY evicted from source lands here |
| PR description | YES | ditto |
| Slack / Jira bodies | YES | `outbound-comms` adds nested-list shape + clickable links |
| README, public docs, postmortems, customer comms | NO | clarity over brevity — full prose |
