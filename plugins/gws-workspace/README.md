# 📄 gws-workspace

    /plugin install gws-workspace@cc-millz

Drive Google Workspace from an agent through one CLI instead of a Workspace MCP server. The skill carries the call shape, the shared flags and the per-service resource tables for Docs, Sheets, Slides, Tasks and Drive, so a method's required params come from `gws schema` rather than from a web search — and it carries the one finding that costs an afternoon to rediscover: on Google Docs, `gws drive comments create` posts an **unanchored** comment no matter what anchor you supply. Extracted from a private monorepo.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `gws-workspace` | 📄 The call shape and the shared flag set, per-service resource tables plus the `+read` / `+write` / `+append` / `+upload` helpers, the auth ladder, the safety rules, and schema discovery |
| reference | `references/gws-docs.md` | 📝 Docs v1 — `documents.get` / `create` / `batchUpdate`, and `+write` for a plain-text append |
| reference | `references/gws-sheets.md` | 📊 Sheets v4 — `spreadsheets.values` operations, `+read` (read-only) and `+append`, single-row and bulk |
| reference | `references/gws-slides.md` | 🖼 Slides v1 — native vs uploaded presentations, reading slide text out of the JSON, page thumbnails |
| reference | `references/gws-tasks.md` | ✅ Tasks v1 — task lists and tasks, `patch` vs `update` semantics, the per-user limits |
| reference | `references/gws-drive.md` | 🗂 Drive v3 — files, permissions, comments, replies, shared drives, `export` vs `get?alt=media`, `+upload` |
| reference | `references/gdocs-comments.md` | 💬 The comment recipe both ways, the browser traps, and the two-halves verify step |

The plugin ships **no command and no script**: everything is the skill and its six references. There is no `/name` here to collide with another plugin's, and nothing new appears on PATH — the only executable involved is the third-party CLI below, which you install yourself.

## Requirements

One hard requirement, with no fallback. This skill documents that binary and nothing else, so without it there is nothing to run:

| Tool | Required | Comes from | Install |
| --- | --- | --- | --- |
| `gws` | always | the `@googleworkspace/cli` npm package — Google's own Workspace CLI, Apache-2.0, [googleworkspace/cli](https://github.com/googleworkspace/cli); its own `--version` prints "This is not an officially supported Google product" | `npm install -g @googleworkspace/cli` or `bun install -g @googleworkspace/cli` |
| `gcloud` | first run only | the Google Cloud SDK | needed by `gws auth setup`, which configures the GCP project and OAuth client; not needed again afterwards |

Authentication is three commands, once per machine, in this order:

    gws auth setup    # configure the GCP project + OAuth client that login depends on
    gws auth login    # browser-based OAuth
    gws auth status   # the read-only check — run it first on any 401 or 403

## Comments on a Google Doc

Worth reading before you try it, because the API accepts the thing that does not work:

| Want | Path |
| --- | --- |
| A general note — card in the comments panel, the passage quoted, nothing highlighted | `gws drive comments create` |
| An anchored inline comment, highlighted the way a human left it | the Docs UI, driven by a browser tool — the only path |

Drive's `comments.create` echoes an `anchor` back to you and Docs then renders the comment as **"Original content deleted"**: orphaned, no highlight. That holds for a Docs-API `createNamedRange` id and for the documented JSON region alike, and `anchor != null` on a listed comment proves nothing about how that comment was created. [gdocs-comments](skills/gws-workspace/references/gdocs-comments.md) has the working recipe for both paths, the focus traps that put your text into the document body instead of the comment box, and the export-and-`diff` check that proves the body came out untouched.

## Safety

The skill asks before every write or delete, rehearses destructive calls with `--dry-run` first, and never prints credentials or tokens. Scratch files — a downloaded `.pptx`, a before/after export, the stray zero-byte `download.html` that `comments delete` drops into the current directory — go to the OS temp dir, so nothing lands beside tracked source.

---

Part of [cc-millz](../../README.md).
