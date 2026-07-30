---
name: phpstorm-mcp
description: >-
  Use PhpStorm's MCP server as the primary surface for indexed code — symbol
  lookup, call hierarchy, structural search, inspections, refactoring, project
  metadata, and IDE-backed SQL. Use when navigating or editing code while
  PhpStorm is running, when finding who calls a symbol, when validating an edit,
  or when a `mcp__phpstorm__*` call returns an unknown-tool error.
---

# PhpStorm MCP

The IDE has already parsed, indexed, and type-resolved the project. Its answers are
**resolved**, not matched — `analyze_calls` knows a caller from a comment mentioning
the method, and `search_symbol` knows a declaration from a string literal. Prefer it
over text tools for anything the index covers.

Grep / Glob / Read stay correct for what the index does **not** cover: docs, logs,
YAML, JSON, fixtures, lockfiles, and any file outside a content root.

## Tool map

| Need | Tool |
| --- | --- |
| Where is this declared | `search_symbol(q, paths[])` |
| Signature, PHPDoc, type | `get_symbol_info(filePath, line, column)` |
| **Who calls this** | `analyze_calls(symbolFqn, "INCOMING_CALLS")` |
| What does this call | `analyze_calls(symbolFqn, "OUTGOING_CALLS")` |
| Code shape, not text | `search_structural(pattern, fileType)` |
| Literal text | `search_text(q, paths[])` |
| Regex | `search_regex(q, paths[])` |
| File by glob | `search_file(q)` |
| Problems in one file | `get_inspections(filePath, minSeverity)` |
| Problems across files | `lint_files(files[], min_severity)` |
| Apply an offered fix | `apply_quick_fix` |
| Rename everywhere | `rename_refactoring` |
| PHP version, interpreter, extensions | `get_php_project_config` |
| Installed packages | `get_composer_dependencies(nameFilter)` |
| Runnable entry points in a file | `get_run_configurations(filePath)` |
| Toggle any IDE setting or action | `search_ide_actions(query)` → `invoke_ide_action(actionId)` |

Always pass `projectPath` — it removes an ambiguity round-trip on every call.

## Callers: use the hierarchy, not the haystack

`analyze_calls` is the single highest-value tool here and the easiest to forget.
Grepping a method name returns definitions, doc mentions, same-named methods on
unrelated classes, and string literals. `analyze_calls` returns the actual call
graph, already resolved through inheritance and interfaces.

Pass a fully qualified name (`App\Service\Booking.refund`). Ambiguous? The error
returns exact signatures — pass one back. Only know a fragment? `search_symbol`
first. Page big trees with `treePath` + `childOffset` rather than raising `maxNodes`.

## After every edit

`get_inspections(filePath, minSeverity="WARNING")` — the same engine that draws the
squiggles, including type errors a linter run from the shell will not catch. Editing
several files? One `lint_files` call beats N inspection calls.

Returned problems carry their available quick fixes; `apply_quick_fix` applies one
without you rewriting the line by hand.

## Search scoping

`paths[]` takes project-relative globs and supports `!` excludes, so scope at the
call instead of filtering results:

```
paths: ["src/**", "!**/tests/**"]
```

Trailing `/` expands to `**`. A pattern with no `/` becomes `**/pattern`.
`search_symbol` searches project sources only — retry with `include_external=true`
to reach vendor and SDK symbols.

## Databases

The IDE's configured connections are queryable directly: `list_database_connections`
→ `execute_sql_query` → `fetch_query_result`, plus `introspect_schema`,
`list_schema_objects`, `preview_table_data`, and `get_database_object_description`.

Useful when the IDE already holds credentials a shell client would need re-supplied.
For scripted or repeatable work a CLI client is still the better tool — this lane is
for ad-hoc reads while reasoning about code.

## Tool names changed in 2026.2

Two names were replaced. Calling the old ones returns an unknown-tool error:

| Removed | Use |
| --- | --- |
| `search_in_files_by_text(fileMask)` | `search_text(q, paths[])` |
| `find_files_by_name_keyword` | `search_file(q)` |

The `fileMask` string parameter is gone with them — scoping is the `paths[]` glob
array described above.

Debugging PHP at runtime is a separate surface — load `phpstorm:phpstorm-debug`.
