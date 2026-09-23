# 🎬 video-reader

    /plugin install video-reader@cc-millz

Fetch, transcribe and read ONE video of any length, from a URL on any site yt-dlp supports or from a local file, and report what is **said** and **visible**, never what is guessed. What comes out is a directory of inspectable artifacts: provenance, a canonical transcript, chapters, time-sampled frames and contact sheets with an index that maps every cell to its timestamp. Captions are used when the source has them; otherwise a local whisper build transcribes the audio, when one is already installed. Nothing authenticates, nothing is installed behind your back, and nothing leaves the machine. Extracted from a private monorepo.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `video-reader` | 🎞 The reading procedure: acquire, read the report, the transcript, the chapters and every sheet, answer with timestamps; follow-ups through dense windows and close-ups; the untrusted-input rule; the honest answer when no transcript exists |
| script | `scripts/video-read.sh` | 🛠 The whole runnable surface: metadata preflight, acquisition with provenance, `ffprobe` inventory, caption-track choice, local speech-to-text, seek-based frames, scene cuts, indexed contact sheets, chapters, `--window`, `--zoom` and a guarded `--remove-tmp` |

The plugin ships **no command**: everything is the skill plus one script, so there is no `/name` here to collide with another plugin's.

## Requirements

Three tools are needed for **every** run, and a fourth for URL input. A missing one exits `3` naming it and the line that installs it:

| Tool | Required | Needed for | Install |
| --- | --- | --- | --- |
| `ffmpeg` | always | frames, contact sheets, audio export | `brew install ffmpeg` |
| `ffprobe` | always | the stream inventory every later step reads | `brew install ffmpeg` |
| `jq` | always | the profile, the caption plan, `report.json`, `--explain` | `brew install jq` |
| `yt-dlp` | URL input | metadata preflight and acquisition | `brew install yt-dlp` |

Optional extras, each absent by default and never installed for you:

- **whisper.cpp** (`whisper-cli` or `whisper-cpp`) plus a multilingual GGML model: `brew install whisper-cpp`, then a model. The script finds models in the usual stores; `VIDEO_READER_WHISPER_MODEL` points at a specific `.bin`. English-only `.en` models are never picked. Python `whisper`, `faster-whisper` and `whisperx` are detected too, but only suggested, since they may download a model on first use.
- **tesseract**: `brew install tesseract`, plus `brew install tesseract-lang` for non-Latin on-screen text.

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/video-read.sh" --probe   # what this machine has, printed for a human
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/video-read.sh" --explain # the same detection as JSON, writes nothing

## What a run produces

    {workdir}/<slug>/
      report.json          provenance and the status of every stage
      transcript.txt       canonical transcript, "[hh:mm:ss] line"
      transcript.srt       the same track untouched, original cue timing
      chapters.tsv         when the source has chapters
      sheets/sheet-NN.jpg  4x4 contact sheets in time order
      sheets/index.tsv     sheet, cell, t_s, hms, kind, frame for every cell
      frames/              interval samples and scene cuts
      subs/ media/ logs/   every caption track, the media, one log per tool

- **Transcript**: captions first, chosen from the metadata before download (original language first, English second, an English companion kept beside a non-English track), then local whisper.cpp, then an explicit "not analyzed". Only auto-caption tracks get their rolling duplicates collapsed in `transcript.txt`.
- **Frames**: at most 120 interval samples at any length, each pulled by an input seek, so an 18-minute talk samples in about 25 s and a 30-hour synthetic file in 4 s. Scene cuts come from a full scan up to 20 minutes of video, at most 60 spread over the whole timeline; `--scene N` scans longer videos too.
- **Follow-ups**: `--window <run> <from> <to> [step]` samples one stretch densely, `--zoom <run> <sec> [crop]` pulls one close-up. Neither downloads again.
- **Limits**: none by default. `--max-duration` and `--max-size` are opt-in and trip exit `2`. Duration is compared exactly: a URL's from its metadata before any media downloads, a file's from `ffprobe`. Size is compared by the byte: a local file before the copy, a URL by yt-dlp during the download and again on the merged file, since a size is not always known in advance.

## Where the files land

The scratch base is resolved by three rungs, in this order, and `--explain` reports which one answered as `sources.workdir`:

| Rung | Set by | `sources.workdir` | A relative value anchors to |
| --- | --- | --- | --- |
| 1 | the `VIDEO_READER_DIR` environment variable | `detected:env` | the current directory |
| 2 | `workdir` in a committed `.video-reader.json`, found by walking up from the current directory to `$HOME` or `/` | `profile` | the profile file's own directory |
| 3 | the OS temp dir, in a `video-reader` subdirectory of it, never the temp dir bare | `default` | — |

The base is refused outright when a rung resolves `/`, `$HOME`, or a directory carrying a `.git` entry, and the refusal names the rung.

```json
{
  "workdir": "tmp/video-reader",
  "max_duration": 7200,
  "max_size_mb": 2048,
  "max_height": 720,
  "stt_lang": "en"
}
```

Every key is optional. Full contract: [the `--explain` convention](../../README.md#the---explain-contract).

## The delete guard

`--remove-tmp <run-dir>` deletes one run directory, and both of these must hold:

- the directory carries `.video-reader-run` holding the magic string `video-reader/run/v1`, written the moment this tool created it; a `report.json` is **not** proof of ownership, since several test reporters write one;
- the directory lies under the base this run resolved.

A directory that already exists without the marker is refused as a run target rather than adopted. A re-run of the same slug drops only the artifact names this tool writes, then acquires again.

## Usage

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/video-read.sh" <url|file> [flags]
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/video-read.sh" --window <run-dir> <from> <to> [step]
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/video-read.sh" --zoom <run-dir> <sec> [crop]
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/video-read.sh" --remove-tmp <run-dir>

Flags: `--slug NAME` · `--max-duration SEC` · `--max-size MB` · `--max-height PX` · `--interval SEC` · `--scene N` · `--no-scene` · `--audio-only` · `--video-only` · `--no-frames` · `--stt` · `--no-stt` · `--stt-lang CODE`.

Exit codes: `0` ok · `1` acquisition or analysis failure · `2` usage, a limit, a playlist or live stream, an unreadable profile, a refused directory · `3` a missing dependency, with its install line.

Access restrictions are never bypassed. Every yt-dlp call runs with `--ignore-config --no-cookies --no-cookies-from-browser --no-geo-bypass`: no login, no cookies, no DRM, no proxy from a user config. A video you cannot reach stays unreachable.

---

Part of [cc-millz](../../README.md).
