---
name: "idea-config"
description: "Read, diagnose and hand-edit a JetBrains project's `.idea/` directory (PhpStorm, GoLand, PyCharm, IntelliJ IDEA, WebStorm, any IntelliJ-platform IDE). Use when folders show grey or unversioned in the IDE, a nested git repo is missing from the Git tool window, namespaces or source roots resolve wrong, a module path went stale after a rename, or when adding run configurations, debugger servers, path mappings, interpreters or SDKs by editing `.idea/*.xml`, `*.iml` or `.run/*.run.xml`."
---

Set SKILL_DIR to the absolute directory containing this SKILL.md before running bundled commands. Keep the working directory at the target project; bundled paths are resolved from SKILL_DIR.

# JetBrains `.idea/` config

The IDE keeps its project model in memory and writes it back to `.idea/` on its own schedule. A disk edit
made while the IDE runs survives only if the IDE reloads before it saves. Every edit below follows the
protocol for that reason.

The script lives at `${SKILL_DIR}/_plugin/scripts/idea-config.sh`.

## Protocol

| Step | Do | Done when |
| --- | --- | --- |
| 1 Diagnose | `bash "${SKILL_DIR}/_plugin/scripts/idea-config.sh" doctor --root <project>` | findings listed; exit 0 = none, 1 = findings |
| 2 Back up | `bash "${SKILL_DIR}/_plugin/scripts/idea-config.sh" backup --root <project>` | it prints the backup directory; keep that path for the report |
| 3 Pick the route | IDE running (`ide-running` finding): safest is to close the project, edit, reopen; next best is to edit and reload (step 6); the Settings UI suits one-off changes | route stated to the user |
| 4 Edit | the agent's edit tool, one element per change, macros kept (`$PROJECT_DIR$`, `$MODULE_DIR$`) | the diff against the backup shows only the intended lines |
| 5 Validate | `xmllint --noout <file>` for each touched file, then `doctor` again | XML parses; no new findings |
| 6 Reload | project open → tell the user: File ▸ Reload All from Disk, accept any "reload project?" prompt, before touching any IDE setting | the user confirms, or the change shows in the IDE |

- NEVER write an absolute path where the IDE stores a macro: it breaks the file for every other checkout. Use
  `$PROJECT_DIR$` in project files and `$MODULE_DIR$` in `.iml` files instead.
- NEVER round-trip a file through an XML library that rewrites it: JetBrains files reorder and reformat badly.
  Edit the text in place instead.
- NEVER commit per-user files (`workspace.xml`, `shelf/`, `dataSources.local.xml`, `usage.statistics.xml`);
  the sharing table lives in `references/project-model.md`.
- An IDE setting changed before the reload writes the in-memory model over the edit. Restore from the step-2
  backup if that happens, then reload first.

## Script

`scripts/idea-config.sh` reads, never edits project files. Every verb takes `--root DIR`; the default is the
nearest ancestor of the working directory holding `.idea/`.

| Verb | Output | Exit |
| --- | --- | --- |
| `--explain` | one JSON object: `root`, `idea_dir`, `ide`, `ide_running`, `backup_dir`, each with its source | 0; 2 on no `.idea/` or an unreadable `.idea-config.json` |
| `doctor [--json]` | one finding per line: `kind<TAB>file:line<TAB>detail`; `--json` gives one object, shape in the example below | 0 none, 1 findings, 2 usage or bad profile |
| `backup` | copies `.idea/**/*.xml`, root `*.iml`, `.idea/*.iml` and `.run/` into `<backup_dir>/idea-config-backup.<UTC stamp>/`, prints that path | 0 |

| Finding | Means | Fix |
| --- | --- | --- |
| `stale-path` | a `$PROJECT_DIR$`/`$MODULE_DIR$` url in `modules.xml`, `*.iml` or `vcs.xml` points at nothing | repoint it to the renamed directory, or delete the element |
| `unmapped-git` | a nested directory holds `.git` but `vcs.xml` has no mapping for it; the IDE never auto-registers one the parent repo ignores | add `<mapping directory="$PROJECT_DIR$/<dir>" vcs="Git" />` |
| `dead-mapping` | a `vcs.xml` mapping points at a missing directory or one without `.git` | delete the mapping |
| `duplicate-entry` | the same `sourceFolder`/`excludeFolder` element appears twice | keep one |
| `invalid-xml` | the file does not parse | restore from backup, redo the edit |
| `ide-running` | a JetBrains IDE process is up | follow protocol step 3 and step 6 |

```json
{"plugin":"idea-config","profile_file":null,
 "values":{"root":"/p","idea_dir":"/p/.idea","ide":"unknown","ide_running":true,"backup_dir":"/tmp"},
 "sources":{"root":"detected:--root","idea_dir":"detected:.idea","ide":"default","ide_running":"detected:ps","backup_dir":"detected:TMPDIR"}}
```

```json
{"root":"/p","findings":[
 {"kind":"stale-path","file":".idea/vcs.xml","line":4,"detail":"target does not exist: /p/gone"},
 {"kind":"ide-running","file":".idea","line":null,"detail":"info: a JetBrains IDE is running; disk edits may race its model"}]}
```

A committed `.idea-config.json` at the project root may pin `ide` (one of `phpstorm`, `goland`, `pycharm`,
`intellij`, `webstorm`, `rider`, `clion`, `rubymine`, `unknown`) and `backup_dir`; `--explain` reports those as
`profile`.

Limits worth knowing before trusting a clean run:

- `ide` is a hint read from `.idea/` content; a profile `ide` overrides it.
- `ide-running` reads executable names from `ps -ax -o comm=`; a failing `ps` exits 2 rather than report
  no IDE.
- Symlinked files and directories are skipped, in the scan and in `backup`.
- `backup` misses module files nested deeper than the root or `.idea/`: copy those by hand before editing.
- `unmapped-git` scans three levels below the root and skips `.git`, `.idea`, `.run`, `node_modules`,
  `vendor` and every `excludeFolder`.
- An `.iml` that `modules.xml` references is checked when it sits inside the root.
- A `vcs.xml` mapping to a missing directory reports both `stale-path` and `dead-mapping`: one fix clears both.
- Needs Python 3.9+ (stdlib only) behind the `.sh` shim.

## Routing

| Task | Read |
| --- | --- |
| VCS roots, grey or ignored folders, nested repos, modules, `.iml` content/source/exclude roots, package prefixes, macros, what to commit | `references/project-model.md` |
| Run/debug configurations: where they live, sharing them, templates, before-run tasks, env, compound | `references/run-configurations.md` |
| Debugger wiring: Xdebug servers and path mappings, Delve local and remote, pydevd/debugpy, Node attach | `references/debuggers.md` |
| Project and module SDKs, PHP interpreters and language level, Python SDKs, GOROOT/GOPATH, per-machine settings | `references/interpreters-sdks.md` |
| Where a fact came from, how far to trust it | `references/corpus.md` |

A live debug session (breakpoints, frames, evaluation) is out of scope here: in PhpStorm that is
`phpstorm-phpstorm-debug`; inspections and rename refactoring are `phpstorm-phpstorm-mcp`.
