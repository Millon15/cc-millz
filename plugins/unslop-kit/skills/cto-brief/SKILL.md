---
name: cto-brief
description: Shrink a message for a decider (a CTO, manager or lead who approves, funds or unblocks) to five labeled bullets, what's decided, why it matters, what you need from them, by when and the risk if it's wrong. Use for a status update, escalation or approval request to a boss, an exec summary, or on "cto-brief this", "3 bullets", "5 bullets", "what do you need from me". A project outbound skill swaps it in for `unslop-kit:human-brief` when a decider reads the send.
---

# cto-brief

The reader is a decider with ten seconds: five lines, then they know whether to act. `unslop-kit:human-brief`
writes for the colleague who acts on the facts; this skill writes for the one who approves, funds or unblocks. Run
it in `human-brief`'s place, after the cut and before `unslop-kit:unslop` and `review:writing-style`.

## Shape

Five bullets in slot order, each a bold label then one sentence of at most 12 words. The bullets are the whole
message. The labels are `human-brief`'s decision block, so both readers see the same words.

| Slot | Carries | Fails when |
| --- | --- | --- |
| 1 **Decided:** | the decision made, or the one you ask them to make; what changed when nothing was decided | it names an activity: investigated, worked on, started |
| 2 **Why it matters:** | one number a decider weighs: money, customers, %, a date, person-days | its only number is one the team weighs (latency, line count) |
| 3 **Need from you:** | verb first, the options when there is a choice; or "nothing, FYI" | it holds two asks |
| 4 **By:** | the date, and what happens with no reply | it has no date |
| 5 **Risk if wrong:** | what breaks, costs or slips if the decision turns out wrong, with a number or scale | it restates slot 2, or hedges ("some risk") |

An FYI is three bullets: slots 1 and 2, then "**Need from you:** nothing, FYI."

Write in the decider's words: product, customer, money, dates. Repo, service, class and PR names stay behind the
message's links, with every proof, caveat and hedge. So does any fact that settles a doubt only the team had. Link
every noun the decider may open (§ Links). A slot 2 with no number yet states the scale in the decider's words
("every customer", "one country") and when the number lands.

## Links

A link saves the reader a search, so add the ones nobody asked for. Before the send-check, walk every noun and id in
the bullets and ask "would the reader open this?"; yes means link it.

| Noun | Link to |
| --- | --- |
| A record the reader will check or edit: an account, an order, a config entry | the admin page that opens it, deep-linked to the tab or anchor where they act |
| A ticket, PR, commit, alert, thread, dashboard, log query, doc | its own page |
| A code file | nothing in the bullets; a path is proof and stays behind the ticket or doc |

A deep link not at hand gets built from the app's route; one that lands a click short still beats a bare id. A label
counts toward the 12 words, its URL does not; the bold slot label does not count.

## Example

BEFORE, `human-brief`'s own example: a headline, its five-line decision block and three facts for the developer.

AFTER, 42 words:

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
| A send (Slack, ticket, email) | the bullets alone; the outbound skill adds its links and no figure, proof block or headline |
| Chat, "cto-brief this" | the bullets alone, ready to paste (`unslop-kit:unslop-formatting` § Scope) |

## Send-check

- Five bullets with the five labels in slot order, or an FYI's three; nothing above or below them.
- Each bullet one sentence of at most 12 words after its label.
- Slot 1 is a decision or an outcome; slot 2 carries a decider's number or scale; slot 3 is one ask or "nothing,
  FYI"; slot 4 has a date; slot 5 names a different cost than slot 2.
- Every record, ticket, alert or page the decider may open is a link, deep-linked to where they act; no bare id.
- Zero repo, service, class, method or PR names.
