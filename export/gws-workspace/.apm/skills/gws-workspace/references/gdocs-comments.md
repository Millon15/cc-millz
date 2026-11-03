# Google Docs comments

Two kinds, two tools. Pick by what the reader should see.

| Comment | Renders as | Tool |
| --- | --- | --- |
| Unanchored (general) | card in the "All comments" panel, quoted passage shown, nothing highlighted in the body | `gws drive comments create` |
| Anchored (inline, "like a human left it") | highlighted passage + margin card | Docs UI via `claude-in-chrome` — the ONLY path |

Tested 2026-08-19: Drive `comments.create` with `anchor` set to a Docs-API `createNamedRange` id (`kix.…`) OR the documented JSON region (`{"r":"head","a":[{"txt":{"o":..,"l":..}}]}`) is echoed back by the API but Docs renders the comment as **"Original content deleted"** — orphaned, no highlight. Anchors are opaque ids only the editor mints; `anchor != null` on a listed comment proves nothing about how it was created.

## Unanchored via gws

```bash
gws drive comments create \
  --params '{"fileId":"<FILE_ID>","fields":"id,createdTime"}' \
  --json '{"content":"<text>","quotedFileContent":{"mimeType":"text/html","value":"<exact passage>"}}'
```

- `--json` takes the JSON string only — `@file` is NOT supported. Long bodies: a helper script under the OS temp dir (`${TMPDIR:-/tmp}`) that `cat`s the file into `--json` (keeps `$(…)` out of the Bash tool command).
- `quotedFileContent.value` = the passage the comment refers to, verbatim; that is all the reader gets as an anchor.
- `gws drive comments delete` writes a 0-byte `download.html` into CWD — move it out, e.g. to `${TMPDIR:-/tmp}`.
- Before posting, `comments list` with `fields=comments(id,author(displayName),quotedFileContent,content)` — skip passages already commented on.

## Anchored via the Docs UI (claude-in-chrome)

Posts as the user's own Google account. Per comment, in this order:

1. `Cmd+F` as its OWN `computer` call (never inside a batch after a click — the find bar must own focus before any typing); screenshot confirms "Find in document" is open.
2. `find` the "Find in document" textbox → `triple_click` its ref → `type` the passage. Result must read `1 of 1`; pick a longer phrase until it does.
3. `Escape` — closes the bar, the match stays selected.
4. `find` the toolbar "Add comment" button → `left_click` by ref (NOT `Cmd+Option+M`).
5. `find` the draft textbox + "Post Comment" button → click textbox by ref, `type` the body, click Post by ref. Coordinate clicks on Post silently miss; ref clicks land.
6. Screenshot: the passage turns yellow and the card shows a timestamp.

| Trap | What happens | Recovery |
| --- | --- | --- |
| Typing or a shortcut right after a coordinate click | focus falls through to the document body — text lands in the doc, `Cmd+Return` inserts a page break | toolbar Undo (ref/coordinate click, `Cmd+Z` may not register); verify with a zoom screenshot |
| Toolbar Undo | ALSO un-posts the most recent comment draft (text intact, buttons back) | re-post via the "Post Comment" ref |
| `Cmd+F` inside a batch after a click | the find bar does not open; the phrase is typed into the doc | as row 1 |

**Verify, both halves:**

- `gws drive comments list … fields=comments(id,anchor,quotedFileContent(value))` — every new comment carries an `anchor`.
- Body untouched: `gws drive files export --params '{"fileId":"<ID>","mimeType":"text/markdown"}' -o "${TMPDIR:-/tmp}/after.md"` and `diff` against an export taken BEFORE the session. Identical = the accidental edits (if any) are fully undone; version history still shows them as your edits + reverts.
