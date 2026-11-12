---
name: cto-brief
description: Shrink a message for a decider (a CTO, manager or lead who approves, funds or unblocks) to five labeled bullets, what's decided, why it matters, what you need from them, by when and the risk if it's wrong; `--long` adds a headline and at most 8 flat facts for a reader who also acts on them. Use for a status update, escalation or approval request to a boss, an exec summary, a handoff that must keep its facts listed; on "cto-brief this", "5 bullets", "what do you need from me", "facts only", "one by one". A project outbound skill swaps it in for `unslop-kit:human-brief` when a decider reads the send, and passes `--long` when the facts must stay listed.
---

# cto-brief

The reader is a decider with ten seconds: five lines, then they know whether to act. `unslop-kit:human-brief`
writes one paragraph for the colleague who acts; this skill writes for the one who approves, funds or unblocks, and
its `--long` form for a reader who decides and then works from the facts. Run it in `human-brief`'s place, after
the cut and before `unslop-kit:unslop` and `review:writing-style`.

## Shape

Five bullets in slot order, each a bold label then one sentence of at most 12 words. The bullets are the whole
message.

| Slot | Carries | Fails when |
| --- | --- | --- |
| 1 **Decided:** | the decision made, or the one you ask them to make; what changed when nothing was decided | it names an activity: investigated, worked on, started |
| 2 **Why it matters:** | one number a decider weighs: money, customers, %, a date, person-days | its only number is one the team weighs (latency, line count) |
| 3 **Need from you:** | verb first, the options when there is a choice; or "nothing, FYI" | it holds two asks, or asks what you could find yourself |
| 4 **By:** | the date, and what happens with no reply | it has no date |
| 5 **Risk if wrong:** | what breaks, costs or slips if the decision turns out wrong, with a number or scale | it restates slot 2, or hedges ("some risk") |

An FYI is three bullets: slots 1 and 2, then "**Need from you:** nothing, FYI." Before you write an ask, answer what you can find yourself; ask the one person who holds the answer.

Write in the decider's words: product, customer, money, dates. Repo, service, class and PR names stay behind the
message's links, with every proof, caveat and hedge. So does any fact that settles a doubt only the team had. Link
every noun the decider may open (§ Links). A slot 2 with no number yet states the scale in the decider's words
("every customer", "one country") and when the number lands.

## Long form, `--long`

Taken when the Skill call's arguments hold `--long`, or the user typed it. The reader decides and then acts on the
facts, so the five slots get a headline above them and the facts below.

| Layer | Budget |
| --- | --- |
| Headline | 1-2 lines, the conclusion, first; dropped when it would repeat Decided |
| Decision lines | the five slots above, in order, at most 15 words after the label |
| Facts | after a bold "**What we know**" line, at most 8 bullets, at most 15 words each, one fact per bullet, one list level |
| Proof block | optional, after the facts, heading "How to verify", fenced commands with the expected result |

A slot with nothing real behind it is dropped, never filled: a Need line saying "nothing, FYI", a By with no date, a
Risk of "low" or "none", a Decided of "nothing yet". A bullet states a fact and never proves one: paths, method
names, queries, timings, caveats and hedges go to the proof block or the ticket. Add the proof block only when the
reader asked how to verify; the facts read without it.

## Links

A link saves the reader a search, so add the ones nobody asked for. Before the send-check, walk every noun and id in
the message and ask "would the reader open this?"; yes means link it.

| Noun | Link to |
| --- | --- |
| A record the reader will check or edit: an account, an order, a config entry | the admin page that opens it, deep-linked to the tab or anchor where they act |
| A ticket, PR, commit, alert, thread, dashboard, log query, doc | its own page |
| A code file | nothing in the bullets; a path is proof and goes to the proof block or the ticket |

A deep link not at hand gets built from the app's route; one that lands a click short still beats a bare id. A label
counts toward the word budget, its URL does not; the bold slot label does not count.

## Example

Long form, for the developer who takes the fix:

```markdown
The evidence rules out a total webhook-consumer outage; the provider-specific failure stays open.

- **Decided:** the order-expiry job stays off until the fix in [ABC-457](url) ships.
- **Why it matters:** [63 paid orders](url) are stuck pending while the provider holds the money.
- **Need from you:** @dev, take the fix in [ABC-457](url).
- **By:** Friday; with no reply, the job stays off another week.
- **Risk if wrong:** truly unpaid orders stop expiring too and keep holding seats.

**What we know**
- [Error 6a981e7b](url) is from staging, not production.
- The [second provider's webhooks](url) kept working during the gap.
- No webhook was applied to [orders created between 12:48 and 11:03 UTC](url).
```

Default form, for the decider, 42 words:

```markdown
- **Decided:** the order-expiry job stays off until [the fix](url) ships.
- **Why it matters:** [63 customers](url) paid but have no confirmed ticket yet.
- **Need from you:** approve a delay notice to those 63 customers.
- **By:** Thursday; with no reply, customers hear nothing.
- **Risk if wrong:** unpaid orders stop expiring too and keep holding seats.
```

The three facts left: they settled doubts the team had, and the decider never had them.

## Where it runs

| Surface | Output |
| --- | --- |
| A send (Slack, ticket, email) | the bullets alone, or the long form; the outbound skill adds its links and no figure |
| Chat, "cto-brief this" | the bullets alone, ready to paste (`unslop-kit:unslop-formatting` § Scope) |

## Send-check

- Default: five bullets with the five labels in slot order, or an FYI's three; nothing above or below them; each
  bullet one sentence of at most 12 words after its label.
- Long form: headline unless it repeats Decided, then only the slots with something real in them, then at most 8 fact
  bullets of at most 15 words under "**What we know**"; zero filler lines.
- Slot 1 is a decision or an outcome; slot 2 carries a decider's number or scale; slot 3 is one ask, or "nothing,
  FYI" in the default form; slot 4 has a date; slot 5 names a different cost than slot 2.
- An ask goes to the one person who holds the answer, and asks for nothing you could find yourself.
- Every record, ticket, alert or page the reader may open is a link, deep-linked to where they act; no bare id.
- Zero repo, service, class, method or PR names in the bullets.
