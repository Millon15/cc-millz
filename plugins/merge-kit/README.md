# 🔀 merge-kit

    /plugin install merge-kit@cc-millz

Two commands for the part of a merge that goes wrong quietly. `/merge-kit:resolve` walks the conflicts of a merge or a rebase — auto-resolving the hunks a stated fact settles, stopping one at a time on the ones it cannot — and `/merge-kit:verify` answers, for any merge, rebase or squash, whether it silently reverted work that had landed on the target after the fork point.

Neither assumes a language, a forge or a directory layout. Both read the project's own facts from `.merge-kit.json`, and detect what the file does not carry.

## Core ideas

- **The forge is never a committed field** — it is read from each repository's own `origin` remote on every run, so a repo that moved between hosts is right immediately instead of stale. `gh`, `bbkt`, `glab`, and an honest `null` for a host with no known CLI.
- **A merge is measured against the fork point, not against the previous commit** — where one side rewrote a region the other side had extended, the extension can vanish with no conflict and nothing in the merge's own diff to show it. `merge-forensics.sh` compares FORK, PRE and POST, and reports the exact lines lost.
- **Mid-conflict is a first-class state** — `--in-progress` autodetects a stopped merge from `MERGE_HEAD` and a stopped rebase from its state directory, reading POST from the index and worktree. The audit runs before anything is committed, twice: once before the walk, once before the commit.
- **A squash is refused rather than guessed** — one parent means git recorded no link back to the source branch, so the fork point is not recoverable. The script exits 2 asking for `--fork` or `--source`; a fabricated fork point produces a confident wrong answer.
- **Auto-resolve is licensed by the net** — the tiering only earns its speed because the audit, the full suite and the pre-commit forensic check all run unconditionally. Every automatic call is logged with the fact that settled it, and echoed for audit before the commit.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| command | `/merge-kit:resolve <repo> <pr>` · `<repo> local <feature> <target>` | 🔀 Tiered conflict resolution — auto for TRIVIAL and OBVIOUS, a one-at-a-time walk for AMBIGUOUS, forensics before the commit |
| command | `/merge-kit:verify <repo> <commit\|pr>` · `<repo> --in-progress` | 🔎 Forensic audit of a merge, rebase or squash — at-risk files, full reverts, the exact lines lost, per-file verdict |
| script | `scripts/merge-kit.sh --explain` | Resolves the repo map, the forge CLI and the test command, and prints them as JSON with a source per key |
| script | `scripts/merge-forensics.sh --repo <path>` | The comparison itself: FORK, PRE, POST, and one JSON verdict |

## Configuration

A committed `.merge-kit.json` at the project root. Everything in it is optional — what it omits is detected, and what cannot be detected is reported as unknown rather than guessed.

```json
{
  "repos": { "api": "services/api", "web": "services/web" },
  "test_commands": { "api": "go test ./... -race" },
  "work_dir": "tmp/merge-kit"
}
```

| Key | Default when absent |
| --- | --- |
| `repos` | the `origin` remotes of the working directory and one level of subdirectories (`detected:origin-scan`) |
| `test_commands` | a Makefile `test` target, then a package manager script with the runner off the lockfile, then a language default (`detected:makefile` · `detected:package-json` · `detected:go-mod` · `detected:cargo` · `detected:python`), then `null` |
| `work_dir` | `tmp/merge-kit` |

There is deliberately **no `forge` key**: the forge comes from each repository's `origin` URL and is always reported as `detected:origin-url`. A `forge` key placed in the profile is ignored.

    scripts/merge-kit.sh --explain [--root <dir>] [--repo <alias|path>]

`--repo` scopes the answer to one repository and is what adds `test_command` — the ladder lands on a different rung per repo, and one source word cannot be honest about several at once.

## Prior art

The three-tier classification in `/merge-kit:resolve` owes its shape to [`mattpocock-skills:resolving-merge-conflicts`](https://github.com/mattpocock/skills), which argues that a conflict is resolved by understanding both intents rather than by picking a side. This plugin adds the profile resolution, the forensic net and the auto-resolve tiering around that idea.

## Provenance

Extracted from a private monorepo.

---

Part of [cc-millz](../../README.md).
