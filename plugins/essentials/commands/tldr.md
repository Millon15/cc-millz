---
description: Re-render what was just said as conclusions + actionable items only.
disable-model-invocation: true
---

Re-render the current discussion — or the part of it named in `$ARGUMENTS`, if any — as
conclusions and actionable items only. I am not going to read the long version.

Load the `essentials:concise-writing` skill and apply its fact test to every line you keep.

## Rules

- **Nothing new.** Work only from what is already in context. No tool calls, no re-reading files,
  no fresh analysis, no recommendation that was not already raised. Compression is an edit.
- **Keep the hard facts** — numbers, units, percentages, identifiers, `file:line`, commit SHAs,
  flag names, URLs. Drop the derivation that produced them, the motivation, the narration of what
  you did, and every hedge that carries no constraint.
- **Keep uncertainty markers.** A measured number and an assumed one do not merge. If something was
  unverified, it stays unverified — say so in three words, not three sentences.
- **No preamble, no sign-off.** No "here's the summary", no "say the word and I'll apply it" — a
  pending decision is an actionable item, not a closing line.

## Shape

```markdown
## Conclusions
- One line each. Front-load the claim; the qualifier comes after the comma, if at all.

## Actionable items
- Imperative first word. Say what changes and where.
- **Decide:** prefix anything blocked on my call, with the options in a half-line.
```

- Max 7 bullets per section. Over that, you are still summarising rather than concluding — merge
  siblings upward into the one parent claim they share.
- A bullet is one line. No nested prose, no sub-bullets unless two items genuinely share a parent.
- Nothing to act on → `## Actionable items` reads `- None.` Never pad it.
- Table only when three or more items compare on the same axes; otherwise bullets.
