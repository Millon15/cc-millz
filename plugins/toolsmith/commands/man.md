---
description: >
  Print tldr-style help for any command, skill, agent or rule in this project, or
  answer a project question — how do I do X here, who owns Y, where does Z live.
  Read-only: it explains and routes, it never runs the thing it describes.
argument-hint: '[<name> | <free-text intent or project question>]'
disable-model-invocation: true
---

# `/toolsmith:man`

Unix-`tldr`-style help for `$ARGUMENTS`, or an answer to a project question. Read-only throughout.

## Phase 0 — Resolve the layout (ALWAYS FIRST)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/toolsmith.sh" --explain
```

| JSON key | What it decides |
| --- | --- |
| `values.skills_dir` · `commands_dir` · `agents_dir` · `rules_dir` | the target universe enumerated below; `null` means the layout has no such layer |
| `values.generated_dirs` | copies of the same tools — read one only where the sources are unreadable, and say which you read |
| `values.knowledge_skill` | the skill the Escalate branch loads for a domain or ownership question; `null` means there is none |
| `values.task_runner` | the ladder a how-do-I answer names, in priority order; an empty ladder means this project declares no runner |

Exit 2 means no layout marker or an unreadable profile — STOP and print the script's own message.

## Dispatch (MUST, in order)

| `$ARGUMENTS` | Mode | Action |
| --- | --- | --- |
| empty | **Usage** | Print this command's own usage block (below) |
| matches a target slug (exact, then case-insensitive substring) | **Lookup** | Render that target's tldr card |
| prose that ranks a confident tool by intent | **Suggest** | Rank the top 3 targets by intent → ranked list + the full card of #1 |
| prose, NO confident tool match, project-question intent | **Escalate** | Answer the project question (§ Project questions) |
| starts with `find ` | **Find** | Search beyond this machine — marketplaces, skills.sh, GitHub |

Slug match: strip a leading `/`, lowercase, compare against command names, skill names, agent names and rule filenames. Several substring hits → Suggest over just those.

**Tool lookup wins first.** Only prose with NO confident tool match escalates. Genuine ambiguity → prefer Suggest, and append a one-line pointer to the knowledge skill.

## Target universe

Enumerate, read-only, from the directories Phase 0 reported:

| Type | Source | Invocation shown |
| --- | --- | --- |
| Command | every `*.md` under `values.commands_dir` (a nested path becomes `group:name`) | `/name <args>`, from its `argument-hint` |
| Skill | every `SKILL.md` under `values.skills_dir` | `Skill(name)` / `/name` / its auto-trigger phrase |
| Agent | every `*.md` under `values.agents_dir` | how it is spawned |
| Rule | every `*.md` under `values.rules_dir` | "Applies when: …" — rules are not invoked |
| Plugin and user skill | the runtime skill list already in this context, plus `~/.claude/skills` | `Skill(name)` / `/name` |

Name and description live in the frontmatter; read the matched file's frontmatter and body to synthesize the card. NEVER pre-generate an index — read live.

Where a layer directory is a dot-directory or excluded by the project's ignore rules, pass it as a path ARGUMENT to the search tool. A glob alone reaches neither.

## Matching signal (Suggest mode)

Rank by intent over descriptions, tags and the runtime skill list already in context. NEVER full-body-scan every target, and NEVER name-grep only — a name grep misses intent ("refund stuck" ranks nothing).

The ranking is done for you:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" "<text>" --no-remote
```

It scores the project, user, installed-plugin and marketplace tiers in one call. Read it alongside the in-context list: the list knows what is enabled right now, the script knows what exists on disk.

Zero local hits → say so in one line and point onward: "nothing local — `/toolsmith:man find <text>` searches marketplaces and skills.sh".

## Card format

```
<target-name>

<one-line description>.
More information: <relative file path or URL>.

- <use-scenario description>:
    <invocation>

- <use-scenario description>:
    <invocation>
```

- 4–8 scenarios, common → advanced. Each is a description line plus an indented real invocation.
- Scenarios are SYNTHESIZED from the body, the `argument-hint`, examples and tags — a target need not declare them.
- Rules: replace the scenarios with `- Applies when: <trigger>` lines, no invocation.
- `More information:` MUST cite the source file path or the external URL the file points to.

## Suggest output

```
No exact match for "<text>". Closest by intent:

1. <name> — <one clause on why it fits>
   <invocation>
2. <name> — <why>
   <invocation>
3. <name> — <why>
   <invocation>

─── tldr · <name> ───
<full card for #1>
```

## Find mode (`/toolsmith:man find <query>`)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-skill.sh" "<query>" --remote
```

Print the ranked table, then ONE adoption line per hit worth acting on, taken from the `toolsmith:skill-discovery` adoption table: enable an installed plugin · unlock a locked skill · install a marketplace one · vendor a GitHub skill · read it in place.

This command stays read-only: it NEVER installs, enables, unlocks or vendors. It names the command the user would run.

## Project questions (Escalate mode)

Prose with no confident tool match and a project-question intent is not a tool lookup. Answer it; do not force a bad card.

| Intent | Signal words | Answer via |
| --- | --- | --- |
| **who-to-ask** | who / which team / owns / contact / responsible | `values.knowledge_skill` when the profile declares one; where it is `null`, say the project declares no knowledge skill and answer from what is readable in the repo — never invent an owner |
| **how-do-I** | how do I / how to / what command / run / build / test / deploy | the `values.task_runner` ladder: take the FIRST entry and list its targets read-only (`just --list`, `make -qp`, a package manifest's scripts), then name the exact target. An empty ladder means the project declares no runner — say so and point at its own documentation |
| **domain / where** | where is X / what handles Y / which service owns | `values.knowledge_skill`, else the repo's own documentation entry point |

- The knowledge skill is the ONLY skill this command may load, and ONLY on this branch. Usage, Lookup, Suggest and Find stay read-only and load nothing.
- how-do-I MAY LIST a runner's targets to name the real one. It NEVER runs one.
- Still uncertain after escalating → say so. NEVER fabricate an owner, a channel or a command.

## Usage block (empty argument)

```
man — quick help for any command, skill, agent or rule, or any project question.

- Show help for a known target:
    /toolsmith:man <name>

- Find the right tool from a description:
    /toolsmith:man <what you want>

- How do I do X in this project:
    /toolsmith:man how do I <task>

- Who do I ask about X:
    /toolsmith:man who owns <area>

- Find a skill anywhere (marketplaces, skills.sh, GitHub):
    /toolsmith:man find <what you want>

- This help:
    /toolsmith:man
```

## Guardrails

- NEVER run or spawn a target — this is help, not execution. The single exception is loading `values.knowledge_skill` on the Escalate branch.
- NEVER edit or write any file. Listing a task runner's targets is read-only; running one is not.
- MUST read the layer directories Phase 0 reported, never a hard-coded path.
- Keep the cards `tldr`-brief — no prose walls, no full body dumps.
- Match case-insensitively and `/`-insensitively.
- Zero plausible suggestions → say so and show the 3 nearest names rather than guessing.
