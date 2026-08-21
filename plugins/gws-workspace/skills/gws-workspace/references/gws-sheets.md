# sheets (v4)

```bash
gws sheets <resource> <method> [flags]
```

## API Resources

### spreadsheets

| Method | Description |
| --- | --- |
| `get` | Returns the spreadsheet at the given ID (grid data not returned by default — use `fields` or `includeGridData`) |
| `create` | Creates a spreadsheet |
| `batchUpdate` | Applies one or more updates. If any request is invalid, the entire batch fails |
| `getByDataFilter` | Returns spreadsheet with data filtered by `dataFilters` parameter |

### spreadsheets.values

Operations on cell values (get, update, append, batchGet, batchUpdate, batchClear, clear).

### spreadsheets.sheets

Operations on individual sheets within a spreadsheet (copyTo).

### spreadsheets.developerMetadata

Operations on developer metadata (get, search).

## Helper: +read

Read values from a spreadsheet. **Read-only** — never modifies data.

```bash
gws sheets +read --spreadsheet <ID> --range <RANGE>
```

### Flags

| Flag | Required | Default | Description |
| --- | --- | --- | --- |
| `--spreadsheet` | yes | — | Spreadsheet ID |
| `--range` | yes | — | Range to read (e.g. `Sheet1!A1:B2`) |

### Examples

```bash
gws sheets +read --spreadsheet ID --range 'Sheet1!A1:D10'
gws sheets +read --spreadsheet ID --range Sheet1
```

### Tips

- Supports various range formats, including entire sheet references
- For advanced options, use the raw `values.get` API

## Helper: +append

Append rows to a spreadsheet.

```bash
gws sheets +append --spreadsheet <ID>
```

### Flags

| Flag | Required | Default | Description |
| --- | --- | --- | --- |
| `--spreadsheet` | yes | — | Spreadsheet ID |
| `--values` | — | — | Comma-separated values (simple single-row append) |
| `--json-values` | — | — | JSON array of rows, e.g. `'[["a","b"],["c","d"]]'` |

### Examples

```bash
# Simple single row
gws sheets +append --spreadsheet ID --values 'Alice,100,true'

# Multi-row bulk insert
gws sheets +append --spreadsheet ID --json-values '[["a","b"],["c","d"]]'
```

### Tips

- Use `--values` for simple single-row appends
- Use `--json-values` for bulk multi-row inserts

**Write command** — confirm with the user before executing.
