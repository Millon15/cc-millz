# 🧩 idea-config

    /plugin install idea-config@cc-millz

Read, diagnose and hand-edit a JetBrains project's `.idea/` directory from an agent, for any IntelliJ-platform IDE: PhpStorm, GoLand, PyCharm, IntelliJ IDEA, WebStorm and the rest. It covers VCS root mappings for nested repos, module content and source roots with package prefixes, excludes, run configurations, debugger servers and path mappings, interpreters and SDKs. Every format claim in the references cites a tiered corpus of JetBrains docs and intellij-community source. Extracted from a private monorepo.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `idea-config` | 🧩 The edit protocol (diagnose, back up, edit, validate, reload), the finding-to-fix table, and routing to five references |
| script | `scripts/idea-config.sh` | 🩺 `--explain`, a read-only `doctor` and `backup`; never edits project files |
| references | `skills/idea-config/references/` | 📚 `project-model.md`, `run-configurations.md`, `debuggers.md`, `interpreters-sdks.md`, `corpus.md` |

The plugin ships **no command** and **no hook**.

## Why a protocol

- **The IDE owns the file while it runs.** It keeps the project model in memory and writes it back to `.idea/`; a disk edit survives only when the IDE reloads before it saves. The skill backs up first and ends every edit with File ▸ Reload All from Disk.
- **Macros, not paths.** `$PROJECT_DIR$` and `$MODULE_DIR$` keep a file portable across checkouts; an absolute path breaks it for everyone else.
- **Text edits, not XML rewrites.** A parser round-trip reorders attributes and reformats the file; the agent edits the lines in place.

## Doctor findings

| Finding | Means |
| --- | --- |
| `stale-path` | a macro url in `modules.xml`, `*.iml` or `vcs.xml` points at a directory that no longer exists |
| `unmapped-git` | a nested directory (up to three levels down) holds `.git` and `vcs.xml` has no mapping for it |
| `dead-mapping` | a `vcs.xml` mapping points at nothing, or at a directory without `.git` |
| `duplicate-entry` | the same source or exclude folder appears twice in an `.iml` |
| `invalid-xml` | a config file does not parse |
| `ide-running` | a JetBrains IDE is up, so disk edits race its in-memory model |

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/idea-config.sh" doctor --root ~/code/my-project
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/idea-config.sh" --explain

## Requirements

- `bash` and Python 3.9+ (stdlib only).
- POSIX `ps` for the `ide-running` check; a failing `ps` exits `2` rather than report no IDE.
- `xmllint` for the validate step: ships with macOS; `apt install libxml2-utils` elsewhere.

## Config

Optional `.idea-config.json` at the project root, committed:

```json
{ "ide": "goland", "backup_dir": "/var/tmp" }
```

`--explain` prints every resolved value with its source: `profile`, `detected:<signal>` or `default`.
