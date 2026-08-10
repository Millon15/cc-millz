# statusline

Two-line Claude Code status line.

```
the-project ❯ cd:PRJ-123 ❯ sd:PRJ-123(front·hook·stats) ❯ [Opus 5 1M High] ❯ 340k·34%
sk:2·3.7k mcp:1(8)·2.2k ❯ 5h:4%·57m ❯ wk:28%·1d17h ❯ fable:22% ❯ €44/20 ❯ $1.23 ❯ b4f0635c-…
```

## Segments

| Segment | Meaning |
| --- | --- |
| `the-project` | directory basename |
| `cd:KEY` | branch of the repo holding the cwd, reduced to its ticket key |
| `⎇rebase` `⚔1` `✗2` `?3` `↑2 ↓1` `⇡` | in-progress operation · conflicts · tracked edits · untracked · ahead/behind · no upstream |
| `sd:KEY(repo·repo)` | nested repos currently off trunk, grouped by ticket key; hidden when there are none |
| `[Opus 5 1M High]` | model, context window, effort, `Fast` when active |
| `340k·34%` | context tokens used and the share of the window |
| `sk:2·3.7k` | skills loaded this session and their measured token weight |
| `mcp:1(8)·2.2k` | MCP servers exercised, tool schemas fetched, estimated weight |
| `5h:4%·57m` `wk:28%·1d17h` | rolling quota windows with time to reset |
| `fable:22%` | per-model weekly caps |
| `€44/20` | extra-usage spend against its cap, in its own currency |
| `$1.23` | session cost |
| `b4f0635c-…` | session id |

## Colors

One rule per meaning:

| Situation | Color |
| --- | --- |
| Protected branch (`master`, `main`, `release`) | red — bold in `cd:`, plain in `sd:` |
| Caution branch (`stage`, `staging`) | yellow |
| Feature branch | blue |
| Conflicts, tracked edits, in-progress operation | red |
| Untracked, unpushed, no upstream | yellow |
| Ladders (context tokens, quota %) | grey → light grey → yellow → red, same steps for both |
| Chrome (separators, parens, session id) | dim grey; every `·` sits one shade below its own segment |

## Declaring nested repos

`sd:` reads a plain list of repo paths relative to the project root — one per
line, `#` comments allowed. First match wins:

1. `$STATUSLINE_REPOS_FILE`
2. `<project>/.claude/statusline-repos.txt`
3. `<project>/.rulesync/statusline-repos.txt`

No file means no `sd:` segment, which is the right default outside a monorepo.

## Settings

| Variable | Default | Effect |
| --- | --- | --- |
| `CLAUDE_USAGE_TTL` | 45 | seconds before quota is refetched |
| `CLAUDE_DIRTY_TTL` | 60 | seconds before repos are rescanned |
| `CLAUDE_MCP_TOKENS_PER_TOOL` | 280 | tokens assumed per MCP tool schema |
| `STATUSLINE_REPOS_FILE` | — | explicit path to the nested-repo list |

## Install

Enabling the plugin is enough — a `SessionStart` hook writes
`statusLine` into `~/.claude/settings.json` and re-points it after every version
bump. Any previous `statusLine` is saved once to
`~/.claude/statusline-previous.json`; `scripts/uninstall.sh` restores it.

## Requirements

`bash`, `jq`, `git`, `awk`. Quota, spend and per-model caps come from the
Anthropic OAuth usage API, read with the credentials Claude Code already stores
(macOS Keychain, or `~/.claude/.credentials.json`). Without them those segments
simply do not render.

## Costs

Roughly 130 ms per render. Repo scans are cached for 60 s and keyed on every
`.git/HEAD`, so a checkout invalidates instantly while file counts age. The
transcript is read incrementally — only bytes appended since the last render.
