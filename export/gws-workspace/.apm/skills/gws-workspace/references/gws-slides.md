# slides (v1)

```bash
gws slides <resource> <method> [flags]
```

## API Resources

### presentations

| Method | Description |
| --- | --- |
| `get` | Gets presentation metadata and all slide content (shapes, text, layout). Returns full JSON |
| `create` | Creates a blank presentation. Accepts optional `presentationId` and title in request body |
| `batchUpdate` | Applies one or more updates to the presentation. If any request is invalid, the entire batch fails |

### pages (sub-resource)

```bash
gws slides presentations pages <method> --params '{"presentationId": "ID", "pageObjectId": "PAGE_ID"}'
```

| Method | Description |
| --- | --- |
| `get` | Gets a single page (slide, layout, or master) by object ID |
| `getThumbnail` | Returns a URL to a PNG thumbnail of the page. Supports `thumbnailProperties.thumbnailSize`: SMALL, MEDIUM, LARGE |

## Native vs Uploaded Presentations

Check `mimeType` from `gws drive files get` to determine the approach:

| MIME type | Type | Read text | Export to PDF |
| --- | --- | --- | --- |
| `application/vnd.google-apps.presentation` | Native | `gws slides presentations get` | `gws drive files export` with `mimeType=application/pdf` |
| `application/vnd.openxmlformats-officedocument.presentationml.presentation` | Uploaded | Download + `python-pptx` (see below) | Download raw .pptx, convert externally |

### Identifying file type

```bash
gws drive files get --params '{"fileId": "FILE_ID", "fields": "id,name,mimeType"}'
```

### Reading native presentations

```bash
# Full JSON with all slides, shapes, and text
gws slides presentations get --params '{"presentationId": "FILE_ID"}'
```

Parse the JSON: `slides[].pageElements[].shape.text.textElements[].textRun.content`

### Reading uploaded .pptx files

`export` does NOT work for uploaded files — MUST download and parse locally:

```bash
# 1. Download the raw .pptx into the OS temp dir
PPTX="${TMPDIR:-/tmp}/presentation.pptx"
gws drive files get --params '{"fileId": "FILE_ID", "alt": "media"}' -o "$PPTX"

# 2. Extract text with python-pptx
uvx --from python-pptx python3 -c "
from pptx import Presentation
prs = Presentation('$PPTX')
for i, slide in enumerate(prs.slides, 1):
    print(f'=== Slide {i} ===')
    for shape in slide.shapes:
        if hasattr(shape, 'text') and shape.text.strip():
            print(shape.text.strip())
    print()
"
```

### Getting slide thumbnails (native only)

```bash
# 1. Get presentation to find page object IDs
gws slides presentations get --params '{"presentationId": "FILE_ID"}' | jq '.slides[].objectId'

# 2. Get thumbnail URL for a specific slide
gws slides presentations pages getThumbnail \
  --params '{"presentationId": "FILE_ID", "pageObjectId": "PAGE_OBJ_ID", "thumbnailProperties.thumbnailSize": "LARGE"}'
```
