# docs (v1)

```bash
gws docs <resource> <method> [flags]
```

## API Resources

### documents

| Method | Description |
| --- | --- |
| `get` | Gets the latest version of the specified document |
| `create` | Creates a blank document using the title given in the request. Other fields (including content) are ignored |
| `batchUpdate` | Applies one or more updates to the document. If any request is invalid, the entire batch fails |

## Helper: +write

Append text to a document.

```bash
gws docs +write --document <ID> --text <TEXT>
```

### Flags

| Flag | Required | Default | Description |
| --- | --- | --- | --- |
| `--document` | yes | — | Document ID |
| `--text` | yes | — | Text to append (plain text) |

### Examples

```bash
# Append text to a document
gws docs +write --document DOC_ID --text 'Hello, world!'
```

### Tips

- Text is inserted at the end of the document body
- For rich formatting, use the raw `documents.batchUpdate` API instead

**Write command** — confirm with the user before executing.
