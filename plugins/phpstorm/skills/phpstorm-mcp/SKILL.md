---
name: phpstorm-mcp
description: >-
  Use PhpStorm's MCP server for inspections on demand or during review,
  rename refactoring, and project metadata when the IDE is connected.
  Use when reviewing a non-trivial PHP change or investigating an IDE finding.
---

# PhpStorm MCP

Code search goes through `rg` / `rg --files` via Bash, with the directory as a
path argument. Read files with the harness's file tool (Claude: `Read`) or
`sed -n`. Search the checkout being investigated, including its worktree when applicable.

PhpStorm MCP, when connected, provides inspections on demand and in review,
rename refactoring, and Xdebug through `phpstorm:phpstorm-debug` after the
project's doctor passes. Use the project's debugger skill when one exists.

## Search and reads

| Need | Command |
| --- | --- |
| Literal code or call sites | `rg -n -F -e '->method(' -e '::method(' <checkout>/<dir>` |
| Files by name | `rg --files <checkout>/<dir> -g '*.php'` |
| Read matching lines in context | `sed -n '20,80p' <checkout>/<path>` |

Read each candidate's receiver and imports to establish its type. Dynamic
dispatch needs manual reading; a matching name alone does not prove a caller.

## Inspections and refactoring

| Need | Tool |
| --- | --- |
| Problems in one file | `get_file_problems` or `get_inspections` |
| Problems across files | `lint_files` |
| Apply an offered fix | `apply_quick_fix` |
| Rename a symbol | `rename_refactoring` |
| PHP version, interpreter, extensions | `get_php_project_config` |
| Installed packages | `get_composer_dependencies` |
| Find or invoke an IDE action | `search_ide_actions(query)` then `invoke_ide_action(actionId)` |

Pass `projectPath` on IDE calls to identify the project.

Run inspections during review, when a reviewer or user asks, and before handing
back a non-trivial PHP change in a file the IDE indexes. Group changed files in
one `lint_files` call when useful; inspections are not an after-every-edit step.

Worktrees and temporary checkouts may resolve against classes in the IDE's main
checkout. Check the reported file and class versions before treating a finding
as evidence about another checkout.

Debugging PHP at runtime uses `phpstorm:phpstorm-debug`; follow the project's
doctor gate, listener policy, and breakpoint cleanup rules when provided.
