---
name: unslop-formatting
description: >
  Millon15's reply contract, a Russian doll over pstack's unslop and umputun's
  writing-style: pass 1 `pstack:unslop` cuts the AI tells from the wording, pass 2
  `review:writing-style` pins every claim to an exact reference and a flat verdict,
  pass 3 lays the reply out as figure-paragraphs (English Check first, TL;DR, then
  per paragraph: emoji claim line, two sentences of prose, a captioned
  hand-drawn ASCII visual, a small numeric table when numbers cluster, a
  blockquote receipt ledger, `---` between paragraphs, every line hard-wrapped
  at 120 columns). Load before every chat reply; the
  unslop-kit SessionStart hook loads it for you. Also on "format this", "my
  format", "unslop and format", "make it read like me".
---

# unslop-formatting

Three passes, fixed order. Wording first, precision second, layout last: layout adds the emoji glyphs and bold lead-ins that unslop would strip if it ran last. On conflict: layout > writing-style > unslop; a project's outbound skill owns the layout of a send and may set its own precedence.

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

## Pass 3: layout, the figure-paragraph skeleton

1. English Check block first, verbatim, when an English Coach rule is active. unslop never rewrites it.
2. TL;DR: one bold lead-in and one to three sentences, conclusion first. Details after, never before.
3. Body as figure-paragraphs separated by `---`. Each paragraph, in this order:
   - Claim line: one emoji glyph, bold, ends in a period. States the paragraph's claim or verdict.
   - Prose: at most two sentences.
   - At most one table, small and numeric (rule 5).
   - At least one caption + visual pair: an italic one-line caption ABOVE the visual (`*Fig n — what it shows (refs)*`), then the visual itself.
   - A `▎` blockquote ledger of 2 to 7 receipt lines: evidence, mechanisms, refs — one fact per line.
4. Visuals are the point: as many as the content honestly supports, ideally one per paragraph (a paragraph is roughly five sentences of underlying content). Every visual is ASCII art you draw by hand inside a plain fence, shape picked from "Drawing the visual" below. A mermaid fence reaches the reader as source text: the TUI draws nothing from it (I wrote the opposite here on 2026-08-20; the user read bare mermaid code all day and corrected me). Mermaid source belongs to Artifacts and HTML pages, where a browser draws it. A large report opens with one annotated map whose ①-④ markers key the paragraphs that follow.
5. Tables: small and numeric. A table whenever numbers cluster or two or more things are compared on two or more attributes, but a cell holds a number, a count, an identifier, a few words at most, and a paragraph carries at most one. A wide table with sentence-length cells is worse than the prose it replaced: shrink it or move the material into the quote ledger. Numbers compared in prose are still a tell.
6. Fenced code with a language tag for anything runnable or literal: commands, paths in bulk, JSON, config, diffs.
7. `[ASSUMPTION]` on any claim you did not verify.
8. NO nested lists, ever. A flat list only for genuinely enumerable short items, and even then a table or a quote ledger usually wins.
9. Hard wrap at 120 columns. No line of the reply runs past 120 characters: prose, claim line, caption, ledger line, table row, fence content, ASCII visual. Break prose at a word boundary and continue on the next line, mid-sentence is fine; a wrapped ledger line continues on its own `>` line; a table row that would pass 120 loses columns or moves into the ledger; a visual that needs more width is redrawn narrower or stacked. The terminal wraps a long line at the window edge, mid-word, wherever the window happens to end; you wrap it first.
10. A closing recap only when the reply runs past roughly forty lines and the reader has lost the TL;DR.

Concise, no filler: what `essentials:concise-writing` says.

### Drawing the visual

One shape per content kind. The reader scans the picture, so every edge carries its label, the whole figure stays under 100 columns, and no edge crosses another; a graph that would need crossing lines becomes an edge list.

| Content | Shape |
| --- | --- |
| Decision tree, resolution order | branch rail: `├─ label ─▶ outcome`, `└─ label`, `▼` into the next level |
| Lifecycle, state machine | state rail: `[a] ──event──▶ [b] ──event──▶ [c]`, one line per path |
| Actor flow, request and response | sequence rail: one column per actor, `│` lifelines, `──msg──▶` arrows |
| Systems, money flows, topology | box map: `┌─┐ │ └─┘` boxes, labelled arrows, ①-④ markers keyed to paragraphs |
| Magnitudes, shares, timings | bar: `████▌ 12.4s  label`, one row per item, one scale |
| Dependency graph with fan-in | edge list by layer: `layer  node ──▶ dep · dep`, or a small adjacency table |

A branch rail and an edge list, drawn:

```text
.plugin.json at repo root
   ├─ key present ───────────────▶ use it
   └─ absent
        ▼
      detect   Makefile · package.json · go.mod
        ├─ hit ────────────────────▶ use it
        └─ miss
             ▼
           degrade   skip the phase, one-line reason
```

```text
L2 products      plan-kit        ──▶ revmux-kit · html-onepager · ralphex
                 ralphex-revmux  ──▶ revmux-kit · ralphex
L1 libraries     revmux-kit      ──▶ revmux
L0 third party   ralphex · revmux · revdiff
```

### Overrides, applied with pass 3

Pass 3 wins over these unslop rules, on chat replies only. Everything else in unslop stands as written, and a layout-free surface keeps all of unslop (a project's outbound skill owns the layout of a send and may set its own precedence).

| unslop rule | Here |
| --- | --- |
| 13 em dashes | Stays. Zero em dashes, no parentheses-as-dashes either. |
| 15 boldface | The bold claim line opening a paragraph is the convention. Bold on every noun is still a tell. |
| 16 inline-header lists | `**Claim.** new detail` opening a paragraph is fine. `**Label:** restating the line` is still banned. |
| 17 title case | Stays. Sentence case headings and captions. |
| 18 decorative emojis | One emoji glyph per claim line or heading is the convention. None inside sentences, none in captions or ledgers. |

### CLI rendering, the hard rules

Claude Code's terminal renderer parses markdown at the top level only. Verified 2026-08-19 by reproducing each case in the TUI; the mermaid row corrected 2026-08-20, after the user read source text where I had claimed a diagram.

| Element | Renders | Breaks |
| --- | --- | --- |
| Table | Top level, blank line before and after | Indented under a bullet or glued to one: raw pipes |
| Fenced code / ASCII visual | Top level, blank line before and after | Inside a bullet: the fence vanishes |
| Mermaid fence | Artifacts and HTML pages, where a browser draws it | In the TUI: source text, no picture. A chat reply draws ASCII instead |
| Heading | Top level | Inside a list item: flattened |
| Blockquote | `▎` bar, inline code intact — the receipt ledger | |
| Horizontal rule `---` | The paragraph separator (a rule, or a literal `---` line on older builds — both divide) | |
| Links | `text (url)` | |
| Line width | Hard-wrapped by you at 120 columns; a newline inside a paragraph or a `>` ledger stays a line break | Any line past 120: the terminal breaks it at the window edge, mid-word |

Every table, fence and visual sits at column zero with a blank line on each side; the figure-paragraph body makes that automatic.

## Scope

Chat replies get all three passes. Commit messages, PR bodies, code comments, docs, Slack, Jira and Linear bodies get passes 1 and 2 only, without the pass-3 overrides; `essentials:concise-writing` and the project's outbound skill own their layout. A project's outbound skill is such an orchestrator when it calls `pstack:unslop`, `review:writing-style` and `essentials:concise-writing` itself and ranks writing-style above unslop on conflict, the same ranking as here; this skill is not in that chain.

## Send-check

- `Skill(skill="pstack:unslop")` is visible in this context window, or pstack is genuinely not installed and you said so once.
- `Skill(skill="review:writing-style")` is visible in this context window, or review@umputun-cc-thingz is genuinely not installed and you said so once.
- English block first and untouched.
- TL;DR before details.
- Zero em dashes, zero chatbot closers.
- Every body paragraph is a figure-paragraph: emoji claim line, ≤2 sentences of prose, ≤1 small numeric table, ≥1 caption-above-visual pair, a 2-7 line `▎` ledger, `---` after it.
- No nested lists anywhere; emoji count ≤ claim lines + headings.
- No line longer than 120 characters anywhere in the reply; a wrapped ledger line continues on its own `>` line.
- Every claim about code, a run or a PR carries a `path:line`, `#n` or link, or wears `[ASSUMPTION]`.
- Every table is small and numeric; every visual, table and fence sits at column zero with blank lines around it.
- Every visual is hand-drawn ASCII in a plain fence, shape from "Drawing the visual"; the reply holds zero ```mermaid fences.
