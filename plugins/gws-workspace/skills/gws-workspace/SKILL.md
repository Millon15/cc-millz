---
name: gws-workspace
description: >-
  Use when interacting with Google Workspace APIs via the gws CLI: Docs,
  Sheets, Slides, Tasks, Drive — or when commenting on a Google Doc
  (unanchored via gws, anchored/inline only via the Docs UI).
---

# gws — Google Workspace CLI

## Usage Triggers

Use this skill when:

- Reading/writing Google Docs or Sheets
- Reading a Google Slides presentation, native or uploaded
- Managing Google Tasks (task lists, tasks)
- Listing, exporting, or uploading files on Google Drive
- Commenting on a Google Doc — general note OR anchored to a passage
- Any `gws` CLI command

## Prerequisites

The CLI is a hard requirement and is never installed for you: `npm install -g @googleworkspace/cli` (or `bun install -g @googleworkspace/cli`) puts `gws` on PATH.

```bash
# One-time: configure the GCP project and the OAuth client that `login` needs
gws auth setup

# Authenticate (browser-based OAuth)
gws auth login

# Verify
gws auth status
```

Run the three in that order on a fresh machine. `gws auth setup` is the first-run step — the CLI's own help describes it as configuring the GCP project plus OAuth client, and it shells out to `gcloud`, so that has to be on PATH too. `gws auth login` cannot succeed without the OAuth client `setup` creates. `gws auth status` is the one read-only check, and it is what to run first when a call comes back 401 or 403.

## Shared Flags

| Flag                        | Description                                             |
| --------------------------- | ------------------------------------------------------- |
| `--format <FORMAT>`         | Output format: `json` (default), `table`, `yaml`, `csv` |
| `--dry-run`                 | Validate locally without calling the API                |
| `--params '{"key": "val"}'` | URL/query parameters                                    |
| `--json '{"key": "val"}'`   | Request body                                            |
| `-o, --output <PATH>`       | Save binary responses to file                           |
| `--upload <PATH>`           | Upload file content (multipart)                         |
| `--page-all`                | Auto-paginate (NDJSON output)                           |
| `--page-limit <N>`          | Max pages with `--page-all` (default: 10)               |
| `--page-delay <MS>`         | Delay between pages in ms (default: 100)                |

## CLI Syntax

```bash
gws <service> <resource> [sub-resource] <method> [flags]
```

## Service Reference

| Service | Reference                              | Common Operations                       |
| ------- | -------------------------------------- | --------------------------------------- |
| Docs    | [gws-docs](references/gws-docs.md)     | get, create, batchUpdate, +write        |
| Sheets  | [gws-sheets](references/gws-sheets.md) | +read, +append, batchUpdate             |
| Slides  | [gws-slides](references/gws-slides.md) | presentations.get, pages.getThumbnail   |
| Tasks   | [gws-tasks](references/gws-tasks.md)   | tasklists.list, tasks.insert/list/patch |
| Drive   | [gws-drive](references/gws-drive.md)   | files.list, files.export, +upload       |

## Google Docs Comments

| Want | Path |
| --- | --- |
| General note, quoted passage, no highlight | `gws drive comments create` (inline `--json`, `@file` unsupported) |
| Anchored inline comment, highlighted like a human left it | Docs UI via `claude-in-chrome` — the Drive API renders ANY supplied anchor as "Original content deleted" |

Recipe, traps (shortcuts fall through to the document body), and the verify step: [gdocs-comments](references/gdocs-comments.md).

## Safety Rules

- **Confirm with user** before executing write/delete commands
- Use `--dry-run` for destructive operations
- Never output secrets (API keys, tokens) directly

## Discovery

```bash
# Browse resources and methods
gws <service> --help

# Inspect a method's required params, types, and defaults
gws schema <service>.<resource>.<method>
```
