---
name: unslop-formatting
description: >
  Millon15's reply contract, a Russian doll over pstack's unslop: pass 1 `pstack:unslop`
  cuts the AI tells from the wording, pass 2 lays the reply out (English Check first,
  TL;DR line, nested bullets with one emoji glyph per top-level item, tables for
  comparisons, fenced code with language tags). Load before every chat reply; the
  unslop-kit SessionStart hook loads it for you. Also on "format this", "my format",
  "unslop and format", "make it read like me".
---

# unslop-formatting

Two passes, fixed order. Wording first, layout second: layout adds the emoji glyphs and bold lead-ins that unslop would strip if it ran last.

## Pass 1: wording, `pstack:unslop`

Gate, before anything else in this skill: if `pstack:unslop` is in your skill list and this context window holds no `Skill(skill="pstack:unslop")` call of yours, make that call now. Reading this file is not loading pstack. The unslop-kit hook names both calls for a reason: a session that loads only the wrapper writes its replies against the fallback below and calls that pass 1. It is not. Repeat the call after compaction, since compaction drops loaded skills.

Then run pstack's 31 patterns and its self-audit ("what makes this obviously AI generated?") over the draft.

Fallback, ONLY when `pstack:unslop` is absent from the skill list (pstack@cc-millz not installed): apply these checks and say so once. Using the fallback while pstack is installed is a violation, not a shortcut.

- No em dashes. Period or comma.
- No AI vocabulary: additionally, crucial, delve, leverage, robust, seamless, landscape, tapestry, testament, underscore, showcase, foster.
- No "not just X but Y", no rule-of-three padding, no filler ("in order to", "it is important to note").
- No chatbot closers ("Let me know if…", "Hope this helps") and no sycophancy ("Great question").
- Active voice with a named actor. Plain word over the fancy synonym. The mechanism or the number instead of the feeling.

### Overrides

This layer wins over these unslop rules. Everything else in unslop stands as written.

| unslop rule | Here |
| --- | --- |
| 13 em dashes | Stays. Zero em dashes, no parentheses-as-dashes either. |
| 15 boldface | A bold lead-in that ends in a period on a bullet is fine. Bold on every noun is still a tell. |
| 16 inline-header lists | `**Label.** new detail` is fine. `**Label:** restating the line` is still banned. |
| 17 title case | Stays. Sentence case headings. |
| 18 decorative emojis | One emoji glyph per top-level bullet or heading is the convention. None inside sentences, none on nested bullets. |

## Pass 2: layout, the reply skeleton

1. English Check block first, verbatim, when an English Coach rule is active. unslop never rewrites it.
2. TL;DR: one bold lead-in and one to three sentences, conclusion first. Details after, never before.
3. Body as nested bullets, two levels deep at most. One emoji glyph per top-level bullet or heading; a reply of five bullets carries five glyphs, not fifteen.
4. A table whenever two or more things are compared on two or more attributes. Prose comparisons are a tell.
5. Fenced code with a language tag for anything runnable or literal: commands, paths in bulk, JSON, config, diffs.
6. `[ASSUMPTION]` on any claim you did not verify.
7. A closing recap only when the reply runs past roughly forty lines and the reader has lost the TL;DR.

Concise, no filler: what `essentials:concise-writing` says.

### CLI rendering, the hard rules

Claude Code's terminal renderer parses markdown at the top level only. Verified 2026-08-19 by reproducing each case in the TUI.

| Element | Renders | Breaks |
| --- | --- | --- |
| Table | Top level, blank line before and after: a box with wrapped cells, six columns and long cells included | Indented under a bullet (2 or 4 spaces) or glued to a bullet line: raw pipes padded to the longest cell |
| Fenced code | Top level, blank line before and after | Inside a bullet: the fence vanishes and the next bullet is glued to the code |
| Heading | Top level | Inside a list item: flattened to plain text |
| Nested bullets | Three levels deep; a numbered list nested in a bullet becomes a., b. | |
| Blockquote | `▎` bar, inline code inside it intact | |
| Horizontal rule `---` | | Printed as the literal `---`. Use a blank line or a heading instead |
| Links | `text (url)` | |

So a table or a code block is never a child of a bullet. Introduce it with a bullet or sentence that ends in a colon, leave the list with a blank line, place the block at column zero, leave another blank line, then resume the list if there is more. A comparison that belongs inside a nested bullet is written as nested bullets, not as an indented table.

## Scope

Chat replies get both passes. Commit messages, PR bodies, code comments, docs, Slack and Jira bodies get pass 1 only; `essentials:concise-writing` and the project's outbound rules own their layout.

## Send-check

- `Skill(skill="pstack:unslop")` is visible in this context window, or pstack is genuinely not installed and you said so once.
- English block first and untouched.
- TL;DR before details.
- Zero em dashes, zero chatbot closers.
- Emoji count is at most the number of top-level bullets plus headings.
- Every comparison is a table, every literal is fenced, and every table or code block sits at column zero with a blank line on each side.
