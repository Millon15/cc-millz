# 🐘 phpstorm

    /plugin install phpstorm@cc-millz

Turns the PhpStorm MCP server into a first-class agent surface. Requires **PhpStorm 2026.2+** with its MCP server enabled.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `phpstorm:phpstorm-mcp` | 🧭 Tool map for indexed code — `analyze_calls` call hierarchy over grep, symbol/structural search, inspections + quick fixes, refactoring, project metadata, IDE-backed SQL; covers the 2026.2 tool renames |
| skill | `phpstorm:phpstorm-debug` | 🐞 Live Xdebug loop — attach to externally-triggered PHP (Docker, CLI, HTTP), breakpoints with conditions, stack + frame values, expression evaluation, mid-flight state mutation; preflight checklist and the Xdebug features that silently do nothing |

## Not a replacement for JetBrains' own plugin

[`phpstorm-plugin@phpstorm-marketplace`](../../RECOMMENDED.md#-jetbrainsphpstorm-claude-marketplace) covers the PHP *language and project* domain — inspections-backed code review, Composer and environment detection, deprecation scans for a target PHP version. This plugin covers the *tooling surface*: how to drive the IDE, and the runtime debugger JetBrains ships nothing for. Run both.

---

Part of [cc-millz](../../README.md).
