---
name: unslop-millz
description: >
  Millon15's reply contract, a Russian doll over pstack's unslop: pass 1 `pstack:unslop`
  cuts the AI tells from the wording, pass 2 lays the reply out (English Check first,
  TL;DR line, nested bullets with one emoji glyph per top-level item, tables for
  comparisons, fenced code with language tags). Load before every chat reply; the
  unslop-kit SessionStart hook loads it for you. Also on "format this", "my format",
  "unslop and format", "make it read like me".
---

# unslop-millz

Two passes, fixed order. Wording first, layout second: layout adds the emoji glyphs and bold lead-ins that unslop would strip if it ran last.

## Pass 1: wording, `pstack:unslop`

Load `pstack:unslop` (Skill tool) once per session and again after compaction. Run its 31 patterns and its self-audit ("what makes this obviously AI generated?") over the draft.

Fallback when `pstack:unslop` is not in the skill list (pstack@cc-millz not installed): apply these checks and say so once.

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

## Scope

Chat replies get both passes. Commit messages, PR bodies, code comments, docs, Slack and Jira bodies get pass 1 only; `essentials:concise-writing` and the project's outbound rules own their layout.

## Send-check

- English block first and untouched.
- TL;DR before details.
- Zero em dashes, zero chatbot closers.
- Emoji count is at most the number of top-level bullets plus headings.
- Every comparison is a table, every literal is fenced.
