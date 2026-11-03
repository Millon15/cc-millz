# drive (v3)

```bash
gws drive <resource> <method> [flags]
```

## API Resources

### files

| Method | Description |
| --- | --- |
| `list` | Lists user's files. Accepts `q` search parameter. Returns trashed files by default — use `trashed=false` to exclude |
| `get` | Gets file metadata. Add `alt=media` param to download content (stored files only — use `export` for Workspace docs) |
| `export` | Exports **native** Workspace document to requested MIME type. Limited to 10 MB. Does NOT work for uploaded files (.pptx, .docx) — use `get` with `alt=media` instead |
| `create` | Creates a file (max 5,120 GB). Use `--upload` for content |
| `copy` | Creates a copy of a file with optional patch updates |
| `download` | Downloads file content. Operations valid for 24 hours |
| `update` | Updates file metadata and/or content. Supports `--upload` for content |

### about

| Method | Description |
| --- | --- |
| `get` | User info, Drive info, system capabilities. **Requires `fields` param** |

### permissions

| Method | Description |
| --- | --- |
| `create` | Creates a permission for a file or shared drive |
| `delete` | Deletes a permission |
| `get` | Gets a permission by ID |
| `list` | Lists file/shared drive permissions |
| `update` | Updates a permission (patch semantics) |

### comments

| Method | Description |
| --- | --- |
| `create` | Creates a file comment. **Requires `fields` param** |
| `delete` | Deletes a comment |
| `get` | Gets a comment. **Requires `fields` param** |
| `list` | Lists comments on a file. **Requires `fields` param** |
| `update` | Updates a comment (patch semantics). **Requires `fields` param** |

On Google Docs, `create` yields an unanchored comment whatever `anchor` you pass — anchored ones go through the Docs UI, see [gdocs-comments](gdocs-comments.md).

### replies

| Method | Description |
| --- | --- |
| `create` | Creates a comment reply |
| `delete` | Deletes a reply |
| `get` | Gets a specific reply |
| `list` | Lists replies to a comment |
| `update` | Updates a reply (patch semantics) |

### drives (shared drives)

| Method | Description |
| --- | --- |
| `create` | Creates a shared drive |
| `get` | Gets shared drive metadata |
| `list` | Lists shared drives. Accepts `q` search parameter |
| `update` | Updates shared drive metadata |
| `hide` / `unhide` | Hides/restores shared drive from default view |

## Helper: +upload

Upload a file to Google Drive with automatic MIME type detection.

```bash
gws drive +upload <file> [flags]
```

### Flags

| Flag | Required | Default | Description |
| --- | --- | --- | --- |
| `<file>` | yes | — | File path to upload |
| `--parent` | — | — | Destination folder ID |
| `--name` | — | source filename | Custom uploaded filename |

### Examples

```bash
gws drive +upload ./report.pdf
gws drive +upload ./report.pdf --parent FOLDER_ID
gws drive +upload ./data.csv --name 'Sales Data.csv'
```

**Write command** — confirm with the user before executing.

## Omitted Resources

Deprecated or rarely used: `teamdrives` (use `drives`), `accessproposals`, `approvals`, `apps`, `channels`, `operations`, `revisions`.
