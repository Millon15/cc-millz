# 🎬 short-video-reader

    /plugin install short-video-reader@cc-millz

Read ONE short video end-to-end and report what is **visible**, never what is guessed. A clip comes in as a URL or a local file; what comes out is a directory of inspectable artifacts — provenance, a stream inventory, sampled frames, contact sheets, whatever captions the source already carried, and a transcript only when a free offline speech-to-text route already exists on the machine. Nothing authenticates, nothing is installed behind your back, and nothing leaves the machine. Extracted from a private monorepo.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `short-video-reader` | 🎞 The reading procedure — acquire, inventory, sample, read the frames in order, and report timestamps with what is on screen at each; the untrusted-input rule for titles, captions and on-screen text; the honest rung-3 answer when no local transcription exists |
| script | `scripts/short-video-read.sh` | 🛠 The whole runnable surface — acquisition with provenance, `ffprobe` inventory, scene-cut plus interval frames, contact sheets, caption sidecars, optional local transcription, `--zoom` close-ups and a guarded `--remove-tmp` |

The plugin ships **no command**: everything is the skill plus one script, so there is no `/name` here to collide with another plugin's.

## Requirements

Three tools are needed for **every** run, and a fourth for URL input. A missing one exits `3` naming it and the line that installs it:

| Tool | Required | Needed for | Install |
| --- | --- | --- | --- |
| `ffmpeg` | always | frame extraction, contact sheets, audio export | `brew install ffmpeg` |
| `ffprobe` | always | the stream inventory every later step reads | `brew install ffmpeg` |
| `jq` | always | the profile, `report.json`, `--explain` | `brew install jq` |
| `yt-dlp` | URL input | acquisition from a URL, with its provenance sidecar | `brew install yt-dlp` |

`yt-dlp` is checked inside the URL branch alone, so a local-file run never needs it.

Optional extras, each absent-by-default and never installed for you:

- **whisper** — any of `whisper-cli`, `whisper-cpp`, `whisper`, `faster-whisper`, `whisperx`, or the `faster_whisper` / `whisper` Python modules. `brew install whisper-cpp` plus a GGML model; point `SHORT_VIDEO_WHISPER_MODEL` at a specific `.bin` to skip the search. With none of them the audio is reported as `not_analyzed` with the reason, and the read continues on frames and captions.
- **tesseract** — `brew install tesseract`, plus `brew install tesseract-lang` for non-Latin on-screen text. Only the language report needs it; frame reading does not.

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/short-video-read.sh" --probe   # what this machine has, printed for a human
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/short-video-read.sh" --explain # the same detection as JSON, writes nothing

Both answer from one detection pass, so they cannot drift into two verdicts about one machine.

## Where the files land

Read this before the first run, not after it. The scratch base is resolved by three rungs, in this order, and `--explain` reports which one answered as `sources.workdir`:

| Rung | Set by | `sources.workdir` | A relative value anchors to |
| --- | --- | --- | --- |
| 1 | the `SHORT_VIDEO_DIR` environment variable | `detected:env` | the current directory |
| 2 | `workdir` in a committed `.short-video-reader.json`, found by walking up from the current directory to `$HOME` or `/` | `profile` | the profile file's own directory |
| 3 | the OS temp dir, in a `short-video-reader` subdirectory of it — never the temp dir bare | `default` | — |

The environment leads on purpose: a project that commits a profile must still be overridable for a single run without editing a committed file. The last rung is a directory, never an error — a user with no project is not a usage mistake.

A run's artifacts live at `{workdir}/<slug>`, and the base is rejected outright when a rung resolves `/`, `$HOME`, or a directory carrying a `.git` entry — a scratch tree does not belong beside tracked source. The refusal names the rung, because the path is only the symptom.

```json
{
  "workdir": "tmp/short-video",
  "max_duration": 600,
  "max_size_mb": 250,
  "max_height": 720,
  "stt_lang": "en"
}
```

Full contract: [the `--explain` convention](../../README.md#the---explain-contract).

## The delete guard

`--remove-tmp <run-dir>` deletes one run directory, and both of these must hold before anything is removed:

- the directory carries `.short-video-reader-run` holding the magic string `short-video-reader/run/v1`, written at the moment this tool created it — a `report.json` is **not** proof of ownership, since several test reporters write one;
- the directory lies under the base this run resolved.

Neither implies the other. Ownership alone would reach a run left under a base you have since moved away from; containment alone deletes any descendant of whatever path was put in `SHORT_VIDEO_DIR`. A directory that already exists without the marker is refused rather than adopted — the tool never plants its marker into somebody else's directory to make it deletable.

## Usage

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/short-video-read.sh" <url|file> [flags]
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/short-video-read.sh" --zoom <run-dir> <sec> [crop]
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/short-video-read.sh" --remove-tmp <run-dir>

Flags: `--slug NAME` · `--max-duration SEC` · `--max-size MB` · `--max-height PX` · `--interval SEC` · `--scene N` · `--video-only` · `--no-audio` · `--no-frames` · `--stt-lang CODE`.

Exit codes: `0` ok · `1` acquisition or analysis failure · `2` usage, an unreadable profile, or a refused delete · `3` a missing dependency, with its install line.

Access restrictions are never bypassed: no cookie flags, no login, no DRM. A clip you cannot reach stays unreachable.

---

Part of [cc-millz](../../README.md).
