---
name: human-brief
description: Shape a message for a human colleague as one paragraph that tells the story in order (verdict, cause, change, proof, bad news, ask), at most 90 words for a send and 180 for a command's closing paragraph, every openable noun linked. Use before any Slack, Jira or Linear body, a handoff or status message to a person, a command's closing paragraph before its report block; on "for humans", "too much text", "one paragraph", "plain words", "explain it". A project outbound skill loads it as its shape step, after the cut and before the reword; the `cto-brief` skill replaces it for a decider, and its `--long` form when the facts must stay listed.
---

# human-brief

The reader is a colleague between two meetings. One paragraph tells them what happened, what changed, how sure we
are and what they do next, in the order they would ask. `essentials:concise-writing` keeps every fact; this pass
keeps the facts that carry the story and moves the rest out. Run it after the cut and before `unslop-kit:unslop`
and `review:writing-style`.

## Shape

| Surface | Words | Sentences |
| --- | --- | --- |
| Send: Slack, DM, ticket comment, handoff (the default) | at most 90 | 3-6 |
| Closer: a command's paragraph right before its rendered report | at most 180 | at most 12 |

One paragraph, no headline, label, bullet or heading. Sentences of 8-20 words, in this order; a step with nothing to
carry is skipped, never filled:

1. Verdict: the state now. "The fix is live and proven." "Nothing proves it works yet."
2. Cause: the mechanism, with one count. "The report read 156,455 rows to find 71."
3. Change: what is different now, in plain mechanics. Name what a human acts on (a job, a flag, a status), never the
   method.
4. Proof: what the check showed, numbers with units. Equivalence first, then the gain.
5. Bad news: the result that went the wrong way, stated plainly, then one sentence on why the verdict still holds.
6. Ask, only when there is one: a person, the ask, a date. Before you write an ask, answer what you can find yourself; ask the one person who holds the answer.

Voice: "I" for your own work, "you" for the reader. Past tense for the work and the proof, present for the state
now. A guess carries its marker ("which I assume is 299 s"); every other sentence states.

Paths, method and class names, queries, ids that only prove a sentence, and doubts only the team had leave the
paragraph for a "How to verify" block after it or for the ticket. Add that block only when the reader asked how to
verify; it holds fenced commands with the expected result.

## Links

Link every noun the reader may open, inside its sentence: a record they will check or edit goes to the admin page,
deep-linked to where they act; a ticket, PR, alert, thread, dashboard or doc to its own page. A code path is proof,
never a link in the paragraph. A deep link not at hand gets built from the app's route; one that lands a click
short still beats a bare id. A closer whose report block already lists the links skips them.

## Example

BEFORE, the long-form example in the `cto-brief` skill: a headline, five labeled lines and three facts.

AFTER, 89 words:

```markdown
[63 paid orders](url) are stuck pending because no webhook was applied to [orders created between 12:48 and
11:03 UTC](url). The order-expiry job stays off until the fix in [ABC-457](url) ships, so none of those orders
expire while the provider holds the money. The [second provider's webhooks](url) kept working and the [error
alert](url) came from staging, so only one provider failed. The cost is that truly unpaid orders stop expiring too
and keep holding seats. @dev, please take ABC-457 by Friday; with no reply, the job stays off another week.
```

The labels are gone, and so is "Why it matters": the first sentence already says it.

## Send-check

- One paragraph; no headline, label, bullet or heading inside it.
- Within the surface budget: a send at most 90 words and 3-6 sentences, a closer at most 180 and 12.
- The first sentence states the verdict; bad news is stated plainly, with why the verdict holds.
- An ask names one person and a date, and asks for nothing you could find yourself; no ask means no ask sentence.
- Every record, ticket, alert or page the reader may open is a link inside the sentence; no bare id.
- No path, method name, query or hedge in the paragraph; a guess carries its marker.
