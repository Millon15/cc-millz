---
name: cto-brief
description: Shrink a message for a decider (a CTO, manager or lead who approves, funds or unblocks) to exactly three bullets, what changed, why it matters and the ask. Use for a status update, escalation or approval request to a boss, an exec summary, or on "cto-brief this", "3 bullets", "what do you need from me". A project outbound skill swaps it in for `unslop-kit:human-brief` when a decider reads the send.
---

# cto-brief

The reader is a decider with ten seconds: three lines, then they know whether to act. `unslop-kit:human-brief`
writes for the colleague who acts on the facts; this skill writes for the one who approves, funds or unblocks. Run
it in `human-brief`'s place, after the cut and before `unslop-kit:unslop` and `review:writing-style`.

## Shape

Exactly three bullets, one sentence each, at most 12 words, in slot order. The bullets are the whole message.

| Slot | Carries | Fails when |
| --- | --- | --- |
| 1 Changed | the outcome, in the reader's terms | it names an activity: investigated, worked on, started |
| 2 Why it matters | one number a decider weighs: money, users, %, a date, person-days | its only number is one the team weighs (latency, line count) |
| 3 Ask | verb first, the options, a deadline, what happens with no reply; or "Nothing needed, FYI." | it holds two asks, or an ask with no deadline |

Write in the decider's words: product, customer, money, dates. Repo, service, class and PR names stay behind the
message's links, with every proof, caveat and hedge. So does any fact that settles a doubt only the team had. Link
every noun the decider may open (§ Links). A slot 2 with no number yet states the scale in
the decider's words ("every customer", "one country") and when the number lands.

## Links

A link saves the reader a search, so add the ones nobody asked for. Before the send-check, walk every noun and id in
the bullets and ask "would the reader open this?"; yes means link it.

| Noun | Link to |
| --- | --- |
| A record the reader will check or edit: an account, an order, a config entry | the admin page that opens it, deep-linked to the tab or anchor where they act |
| A ticket, PR, commit, alert, thread, dashboard, log query, doc | its own page |
| A code file | nothing in the bullets; a path is proof and stays behind the ticket or doc |

A deep link not at hand gets built from the app's route; one that lands a click short still beats a bare id. A label
counts toward the 12 words, its URL does not.

## Example

BEFORE, `human-brief`'s own example, 44 words: a headline ruling out a total webhook outage, then three facts (the
error came from staging, the second provider kept working, no webhook applied between 12:48 and 11:03 UTC).

AFTER, 29 words:

```markdown
- Webhooks stayed up; only [one payment provider's callbacks](url) failed.
- Orders paid in a 22-hour window missed their status update.
- Nothing needed from you; the fix is tracked in [ABC-457](url).
```

The staging fact left: it answered one commenter's doubt, and the decider never had it.

## Where it runs

| Surface | Output |
| --- | --- |
| A send (Slack, ticket, email) | the three bullets alone; the outbound skill adds its links and no figure, proof block or headline |
| Chat, "cto-brief this" | the three bullets alone, ready to paste (`unslop-kit:unslop-formatting` § Scope) |

## Send-check

- Exactly three bullets in slot order, nothing above or below them.
- Each bullet one sentence of at most 12 words.
- Slot 1 is an outcome; slot 2 carries a decider's number or scale; slot 3 is one ask with a deadline, or "Nothing
  needed, FYI."
- Every record, ticket, alert or page the decider may open is a link, deep-linked to where they act; no bare id.
- Zero repo, service, class, method or PR names.
