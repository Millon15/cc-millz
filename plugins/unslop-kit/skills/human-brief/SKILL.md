---
name: human-brief
description: Shape a message for a human colleague as a headline plus flat facts, with any proof in its own block after them. Use before any Slack, Jira or Linear body, a handoff or status message to a person, or a brief for another agent that will draft one; on "for humans", "too much text", "facts only", "one by one", "state it, don't prove it". A project outbound skill loads it as its shape step, after the cut and before the reword.
---

# human-brief

The reader is a colleague on a phone between two meetings. The reading layer is the whole message; proof is a
separate block they can skip. `essentials:concise-writing` keeps every fact; this pass drops the facts that prove
instead of conclude. Run it after the cut and before `unslop-kit:unslop` and `review:writing-style`.

## Shape

| Layer | Budget |
| --- | --- |
| Headline | 1-2 lines, the conclusion or the ask, first |
| Facts | at most 8 bullets, at most 15 words each, one fact per bullet, one list level |
| Context | at most 1 clause inside a bullet when a human needs it: the job's name, who, when |
| Links | at most 1 per bullet, on the noun that has a URL |
| Proof block | optional, after the facts, heading "How to verify", fenced commands with the expected result |

A bullet states a fact; it never proves one. Proof means file paths, `tmp/` artifacts, method and class names,
queries, timings, cohort caveats and hedges ("does not establish", "may indicate"). Each moves to the proof block or
the ticket. Add the proof block only when the reader asked how to verify, and the facts read without it.

## Example

BEFORE, one bullet with its children, 3 lines: "For your 13:46 comment, [error 6a981e7b](url) contains staging
hosts and `OrderNotificationMessage`, not evidence of a PROD consumer failure. The second provider applied webhooks
through the shared hook, queue and consumer path during the gap. The count covers orders created from 12:48 UTC
through 11:03 UTC; it does not establish zero webhook events processed during that period."

AFTER, 3 bullets:

```markdown
The evidence rules out a total webhook-consumer outage; the provider-specific failure stays open, tracked in [ABC-457](url).

- [Error 6a981e7b](url) is from staging, not PROD.
- The second provider's webhooks kept working during the gap.
- No webhook was applied to orders created between 12:48 and 11:03 UTC.
```

## Send-check

- Headline first, conclusion or ask.
- At most 8 bullets, one level, none over 15 words, at most one link each.
- No path, method name, query, timing, caveat or hedge above the proof block.
- Proof block present only when the reader asked how to verify; the message reads without it.
