# Remote skill sources

Wire formats for the rung-R sources. `scripts/find-skill.ts` speaks the first two; the rest are for a human or a model-side call.

## skills.sh search API

The endpoint `npx skills find` calls. Semantic, not lexical — a natural-language query works.

```bash
curl -s 'https://skills.sh/api/search?q=mysql+query&limit=5'
```

```json
{
  "query": "mysql query",
  "searchType": "semantic",
  "skills": [
    { "id": "planetscale/database-skills/mysql", "skillId": "mysql", "name": "mysql", "installs": 7100, "source": "planetscale/database-skills" }
  ],
  "count": 3,
  "duration_ms": 598
}
```

- `SKILLS_API_URL` overrides the host (the CLI honours the same variable) — a suite points it at a dead port to prove the default run is offline.
- A skill's page is `https://skills.sh/<id>`.
- `installs` is the only popularity signal the API returns. No stars, no last-commit date.

## GitHub code search

```bash
gh search code "refund webhook" --filename SKILL.md --limit 10 --json repository,path
```

- 10 requests per minute, authenticated. `gh api rate_limit --jq '.resources.code_search'` shows the remaining budget.
- Literal match on file content, so search a distinctive phrase from the skill body, not a question.
- Returns no description — fetch the file to judge it.

## grep.app (MCP)

```
searchGitHub(query: "<literal phrase>", path: "SKILL.md", language: ["Markdown"])
```

Over a million public repos, literal or regex (`useRegexp: true`, prefix `(?s)` to cross lines). Heavier on mirrors than `gh`: expect `davila7/claude-code-templates`, `*-zh` translations, and skills vendored under `eval/` or `assets/`. Dedupe by skill-dir basename plus description before presenting.

## npx skills (human-facing)

```bash
npx skills find "<query>" [--owner <github-owner>]
npx skills add <owner/repo@skill> --copy -y
```

- `--copy` writes real files instead of a symlink into `~/.claude/plugins` — required if the skill is going to be committed.
- `DISABLE_TELEMETRY=1` or `DO_NOT_TRACK=1` opts out of its anonymous usage ping.
- Installs land in `.claude/skills/` (project) or `~/.claude/skills/` (global). Under a layout whose sources live elsewhere, NEITHER is the source of truth — vendor the skill instead, with `${CLAUDE_PLUGIN_ROOT}/scripts/vendor-skill.sh`, which writes to `values.skills_dir` and records provenance.

## Context7 (MCP)

```
resolve-library-id(libraryName: "...", query: "...")
```

Resolves a library name to its docs, and surfaces that project's own skills repo when it has one. Use it only when the tool being built wraps a named library or CLI.

The `ctx7 skills search|install` CLI subcommands are deprecated upstream and interactive-only — never call them from a session.

## The standard

`SKILL.md` frontmatter needs only `name` and `description`; everything else is optional and tool-specific. Spec: <https://agentskills.io> (repo `agentskills/agentskills`). Cursor, GitHub Copilot, OpenAI Codex and Gemini CLI implement the same format, which is why a skill found in a non-Claude repo usually drops straight in.
