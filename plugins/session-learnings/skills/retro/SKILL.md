---
name: retro
description: Read past Claude and Codex sessions in full with subagents and distill what they show into an id'd fix list. Use when the user asks to search, read or analyze earlier sessions or runs of a command ("read my recent sessions", "retro of the last /feature runs", "what went wrong in session X") to learn from them or to design a new workflow.
argument-hint: "<topic regex | session ids…> [--since D] [--until D] [--command <name>] [--codex] [--design] [--slug <s>]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/sl-retro.sh *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/sl-retro.sh" *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/sl-redact.sh *), Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/sl-redact.sh" *)
---

# Session retro

A retro is only as good as the transcripts read in full. Every session is chosen and every
finding is drawn by a subagent that read the rendered history line by line, and the coverage gate
proves it from the subagent's own Read results. `RETRO` below is
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/sl-retro.sh"`; its verbs print JSONL and `--explain` prints
the resolved config.

## 1. Echo the inputs

Print, before any search: the topic or ids, the window (`--since`/`--until`), the sources
(Claude always; Codex with `--codex`), the slug (default: the topic in kebab-case, at most four
words), the output directory and the deliverable (the R-list; plus a peer design with `--design`).
The output directory is `tmp/retro/<slug>/` when `RETRO --explain` reports `out_root`; otherwise
allocate one with `mktemp -d` and pass `--out <dir>` to every render. Continue without asking.

## 2. Find, then let finders read every candidate (mandatory)

1. `RETRO find <topic|ids> [--since D] [--until D] [--command <name>] [--codex]` lists candidate
   rows. It excludes this session, headless runs, and projects outside this repository root
   (`--all-projects` widens it). A `pruned` row has no transcript left; keep it in the table and
   read only its prompt-history line. `partial` and `unclassified` rows stay separate in the table.
2. Render every `ok`, `partial` and `unclassified` candidate in full: pipe the find rows into
   `RETRO render --slug <slug>-find`. Each row becomes parts of at most `part_lines` lines.
3. Dispatch finder subagents in parallel, one per batch of parts totalling about 4000 lines,
   balanced by line count. Give each the reader rules in § Briefs and this question: is the
   session relevant to the topic, which source-line windows (the `L<n>` markers) hold the
   relevant work, and one line on why. The grep hits in the find row are a hint, never a verdict.
4. Gate each finder with § Coverage. A short finder's batch is re-read once; still short, its
   sessions are marked `unread` in the table.
5. Print the table: harness, id, dates, status, finder verdict, windows, why. Only finder
   verdicts select sessions. Continue without asking.

## 3. Render the chosen windows

`RETRO render --slug <slug> <id>:<from>-<to> …` (an open end is `<id>:<from>-`). The manifest at
`<out>/<slug>/manifest.json` lists every part with its line count, sha256, source window, high-water
mark and every block it left out (skill bodies, reminders, tool-call metadata) by kind and source
line, so nothing is dropped silently.

## 4. Readers

Dispatch reader subagents in parallel, one per batch of about 4000 rendered lines, balanced by
lines. Each gets the reader rules in § Briefs, its exact part paths, and this return schema, each
entry with its timestamp and `part:line`:

- timeline of the run, phase by phase
- failures, each classed: tool error, wrong assumption, skipped step, user correction, flaky env
- user interventions, quoted verbatim
- what worked and should stay
- candidate fixes, each with the evidence lines that motivate it

Each reader writes its report to `<out>/<slug>/reports/<reader>.md` and returns the path.

## 5. Coverage gate

Run § Coverage on every reader. A short reader gets its `missing_ranges` re-dispatched once to a
fresh reader with the same brief. Gate the retry with both readers in one call, `--agent <first>
--agent <retry>`, so their Read lines union. Still short: the report is marked `incomplete` in the
output with the uncovered ranges, and no headline claim rests on it alone.

## 6. Merge and recheck

1. Merge the reports. Every headline claim gets a recheck with `rg -n` or `sed -n` on the
   rendered part it cites, run by you; a claim the recheck does not show is dropped or marked
   `[ASSUMPTION]`.
2. Freshness: `RETRO render --slug <slug> --delta` renders what a live source grew by since its
   high-water mark. A delta part gets a reader and the gate before the R-list is final.

## 7. Present the R-list

Write `<out>/<slug>/findings.json`: a list of `{id, title, evidence[], fix, scope, rationale,
applicability}` with `scope` `personal` or `team` and evidence as `part:line` plus timestamp.
Ids `R1…` are stable: on a resume, read the file first and keep every existing id; a new
finding takes the next number. Write the same list as `findings.md` and scrub it with
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/sl-redact.sh" < findings.md`.

Present each item as id, title, evidence, fix, scope, rationale, applicability, then coverage
(readers passed, incomplete ranges) and one approve line:

```text
Reply by id: "discuss R2 R5" (peer design), "build R3" (implement), "drop R4".
```

An approval to discuss is not an approval to implement.

## 8. Hand off to a design

With `--design`, or when the user asks to discuss findings with a peer:
`/peer-chat:design <out>/<slug>/findings.md --slug <slug>`. The redacted file is the design's
only source; the slug stays the same through the design and its build.

## Briefs

Reader rules, given verbatim to every finder and reader:

```text
Read each assigned part in full with the Read tool, in order, from line 1 to its last line,
2000 lines per call (offset 1, 2001, 4001, …). Every line counts; a coverage check compares the
line numbers your Read calls returned against the part's line count. sed, rg, head and condensed
copies count for nothing. If a Read returns fewer lines than you asked for, continue from the
next unread line. Cite evidence as <part file>:<line> with the timestamp from the nearest
### header.
```

## Coverage

`RETRO coverage --manifest <out>/<slug>/manifest.json --agent <agentId> --parent
${CLAUDE_CODE_SESSION_ID} --files <its parts>` joins every Read call of that subagent to its
successful result and takes the union of the line numbers returned. Repeat `--agent` (or
`--transcript <file>`) to union several readers of the same parts. A returned line counts only when
its text matches the part as hashed. Exit 0: every assigned part
fully covered. Exit 1: JSONL per part with `missing_ranges`. Exit 2: a part changed since the
manifest (re-render it) or a transcript is missing. The `agentId` is in the Agent tool's result.
Coverage proves delivery, never comprehension.
