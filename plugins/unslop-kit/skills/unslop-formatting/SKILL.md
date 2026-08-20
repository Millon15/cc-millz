---
name: unslop-formatting
description: >
  Millon15's reply contract, a Russian doll over pstack's unslop and umputun's
  writing-style: pass 1 `pstack:unslop` cuts the AI tells from the wording, pass 2
  `review:writing-style` pins every claim to an exact reference and a flat verdict,
  pass 3 lays the reply out (English Check first, TL;DR, body as prose paragraphs
  with one emoji glyph and a bold verdict lead-in each, tables for comparisons,
  fenced code with language tags). Load before every chat reply; the unslop-kit
  SessionStart hook loads it for you. Also on "format this", "my format",
  "unslop and format", "make it read like me".
---

# unslop-formatting

Three passes, fixed order. Wording first, precision second, layout last: layout adds the emoji glyphs and bold lead-ins that unslop would strip if it ran last. On conflict: layout > writing-style > unslop, the same ranking the project's `outbound-comms` uses.

## Pass 1: wording, `pstack:unslop`

Gate, before anything else in this skill: if `pstack:unslop` is in your skill list and this context window holds no `Skill(skill="pstack:unslop")` call of yours, make that call now. Reading this file is not loading pstack. The unslop-kit hook names all three calls for a reason: a session that loads only the wrapper writes its replies against the fallback below and calls that pass 1. It is not. Repeat the call after compaction, since compaction drops loaded skills.

Then run pstack's 31 patterns and its self-audit ("what makes this obviously AI generated?") over the draft.

pstack's "Adding soul" step (vary rhythm, let some mess in, first person) belongs to chat replies and prose. On layout-free surfaces (commit messages, PR bodies, code comments, docs, Slack/Jira/Linear bodies) run the 31 patterns and the self-audit, keep "be specific" and "have an opinion", skip the rest of that step; brevity wins there.

Fallback, ONLY when `pstack:unslop` is absent from the skill list (pstack@cc-millz not installed): apply these checks and say so once. Using the fallback while pstack is installed is a violation, not a shortcut.

- No em dashes. Period or comma.
- No AI vocabulary: additionally, crucial, delve, leverage, robust, seamless, landscape, tapestry, testament, underscore, showcase, foster.
- No "not just X but Y", no rule-of-three padding, no filler ("in order to", "it is important to note").
- No chatbot closers ("Let me know if…", "Hope this helps") and no sycophancy ("Great question").
- Active voice with a named actor. Plain word over the fancy synonym. The mechanism or the number instead of the feeling.

## Pass 2: precision, `review:writing-style`

Gate, same shape as pass 1: if `review:writing-style` is in your skill list and this context window holds no `Skill(skill="review:writing-style")` call of yours, make that call now, in the same batch as the pstack call when both are due.

Its User Override Check does not fire here: this skill IS the user's writing rule, and it invokes writing-style deliberately, for these sections. Its markdown-formatting section and its public-docs scope split yield to pass 3 and to the surface's own rules.

- Exact references. Every claim about code, a run, a PR or a ticket carries a `path:line`, PR `#n`, commit hash or link. A plan-internal label ("§2", "Guard 1") gets the file and line it lives at.
- Identities. A finding, test or comment under discussion is named so the reader can look it up: finding R2-3, `test/prune.bats:31`, the comment id as a link.
- Verdict over feeling. State the problem flat, before the evidence: "worse than R2-3 claimed", not "unsettled me". Opinions stay, pass 1 wants them; they attach to the record, not to the mood.
- First-person corrections. Your own earlier claim that did not survive is corrected in first person and named as such: "I ranked this finding low; the probe proves I was wrong."
- Uncertainty named openly, with the check that would close it: "the `stat -c %Y` branch never ran on this host; a Linux CI run settles it." Pairs with pass 3's `[ASSUMPTION]` marker.
- Problem, then what was done, then the proof, in that order, per item.

Fallback, ONLY when `review:writing-style` is absent from the skill list (review@umputun-cc-thingz not installed): apply the list above and say so once.

## Pass 3: layout, the reply skeleton

1. English Check block first, verbatim, when an English Coach rule is active. unslop never rewrites it.
2. TL;DR: one bold lead-in and one to three sentences, conclusion first. Details after, never before.
3. Body as prose paragraphs, not lists. Each paragraph opens with one emoji glyph and a bold lead-in that ends in a period and states the paragraph's claim or verdict; the evidence follows in full sentences with varied rhythm. NO nested lists, ever. A flat list is allowed only for genuinely enumerable short items (filenames, option names), and a table usually beats it.
4. Tables: small and numeric. A table whenever two or more things are compared on two or more attributes, but a cell holds a number, a count, an identifier, a few words at most. A wide table with sentence-length cells is harder to read than the prose it replaced: shrink it (fewer columns, shorter cells) or fall back to labeled paragraphs. Numbers compared in prose are still a tell.
5. Fenced code with a language tag for anything runnable or literal: commands, paths in bulk, JSON, config, diffs.
6. `[ASSUMPTION]` on any claim you did not verify.
7. A closing recap only when the reply runs past roughly forty lines and the reader has lost the TL;DR.

Concise, no filler: what `essentials:concise-writing` says.

### Overrides, applied with pass 3

Pass 3 wins over these unslop rules, on chat replies only. Everything else in unslop stands as written, and a layout-free surface keeps all of unslop (a project's outbound skill, such as the project's `outbound-comms`, owns the layout of a send and may set its own precedence).

| unslop rule | Here |
| --- | --- |
| 13 em dashes | Stays. Zero em dashes, no parentheses-as-dashes either. |
| 15 boldface | A bold lead-in that ends in a period opening a paragraph is the convention. Bold on every noun is still a tell. |
| 16 inline-header lists | `**Label.** new detail` opening a paragraph is fine. `**Label:** restating the line` is still banned. |
| 17 title case | Stays. Sentence case headings. |
| 18 decorative emojis | One emoji glyph per body paragraph or heading is the convention. None inside sentences. |

### CLI rendering, the hard rules

Claude Code's terminal renderer parses markdown at the top level only. Verified 2026-08-19 by reproducing each case in the TUI.

| Element | Renders | Breaks |
| --- | --- | --- |
| Table | Top level, blank line before and after: a box with wrapped cells, six columns and long cells included | Indented under a bullet (2 or 4 spaces) or glued to a bullet line: raw pipes padded to the longest cell |
| Fenced code | Top level, blank line before and after | Inside a bullet: the fence vanishes and the next bullet is glued to the code |
| Heading | Top level | Inside a list item: flattened to plain text |
| Blockquote | `▎` bar, inline code inside it intact | |
| Horizontal rule `---` | | Printed as the literal `---`. Use a blank line or a heading instead |
| Links | `text (url)` | |

A paragraph body makes these rules easy: end the paragraph, blank line, table or fenced block at column zero, blank line, next paragraph. If a rare flat list appears, a table or code block is never its child; leave the list first.

## Scope

Chat replies get all three passes. Commit messages, PR bodies, code comments, docs, Slack, Jira and Linear bodies get passes 1 and 2 only, without the pass-3 overrides; `essentials:concise-writing` and the project's outbound skill own their layout. the project's `outbound-comms` is such an orchestrator: it calls `pstack:unslop`, `review:writing-style` and `essentials:concise-writing` itself and ranks writing-style above unslop on conflict, the same ranking as here; this skill is not in that chain.

## Send-check

- `Skill(skill="pstack:unslop")` is visible in this context window, or pstack is genuinely not installed and you said so once.
- `Skill(skill="review:writing-style")` is visible in this context window, or review@umputun-cc-thingz is genuinely not installed and you said so once.
- English block first and untouched.
- TL;DR before details.
- Zero em dashes, zero chatbot closers.
- Body carries no nested lists; each body paragraph opens with one emoji glyph and a bold verdict lead-in ending in a period.
- Emoji count is at most the number of body paragraphs plus headings.
- Every claim about code, a run or a PR carries a `path:line`, `#n` or link, or wears `[ASSUMPTION]`.
- Every comparison is a table with short numeric cells (no sentence-length cells), every literal is fenced, and every table or code block sits at column zero with a blank line on each side.
