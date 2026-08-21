# 🐘 phpstorm

    /plugin install phpstorm@cc-millz

Turns the PhpStorm MCP server into a first-class agent surface. Requires **PhpStorm 2026.2+** with its MCP server enabled.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `phpstorm:phpstorm-mcp` | 🧭 Tool map for indexed code — `analyze_calls` call hierarchy over grep, symbol/structural search, inspections + quick fixes, refactoring, project metadata, IDE-backed SQL; covers the 2026.2 tool renames |
| skill | `phpstorm:phpstorm-debug` | 🐞 Live Xdebug loop — attach to externally-triggered PHP (Docker, CLI, HTTP), breakpoints with conditions, stack + frame values, expression evaluation, mid-flight state mutation; preflight checklist and the Xdebug features that silently do nothing |
| command | `/phpstorm:setup-xdebug [service]` | 🩺 Get that loop working end-to-end — diagnose every check, walk the fixes that need a human in the IDE, re-verify until green, then prove it with one real pause. Extracted from a private monorepo. |
| script | `scripts/xdebug-doctor.sh` | 🔍 The checks themselves, and the only place they live — IDE process and listening port, the two force-break flags, per service: container up, extension loaded, `client_host`/`client_port`, `PHP_IDE_CONFIG`, server entry, path mapping |

## The doctor

Three unrelated misconfigurations all produce the same symptom — *"Debug session was finished without being paused"*. The doctor prints which one is actually live, with the exact fix per failure.

    bash "${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh"            # every declared service
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh" app        # one
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh" --explain  # the resolved profile as JSON

- Exit codes: `0` every check passed · `1` a check failed · `2` usage, an unreadable profile, or an unknown service name. A service name that matches no row is REJECTED, never silently skipped — an all-clear over zero checks is the one answer this tool must never give.
- Every `docker exec` it runs passes `XDEBUG_MODE=off`, so the doctor never hangs on the very force-break fault it is diagnosing.

### `.xdebug-doctor.json`

Container names, debug ports, server names and path mappings are project facts with nothing to detect, so the profile is required — an absent one exits 2 naming the marker instead of guessing. Commit it at the project root:

```json
{
  "start_cmd": "docker compose up -d {service}",
  "workspace_file": ".idea/workspace.xml",
  "services": [
    {
      "name": "app",
      "container": "app-1",
      "port": 9003,
      "server_name": "app.local",
      "host_dir": "app",
      "remote_root": "/var/www/app"
    }
  ]
}
```

| Key | Source word | Meaning |
| --- | --- | --- |
| `services` | `profile` | the only valid `[service]` arguments, and everything checked per service. `host_dir` + `remote_root` are optional; without both, the path-mapping check is skipped rather than guessed |
| `start_cmd` | `profile` · `default` | how a stopped service comes up. `{service}` is substituted with the service name; default `docker compose up -d {service}` |
| `workspace_file` | `profile` · `default` | the IDE settings file the flag and mapping checks read; default `.idea/workspace.xml` |

The command reads `start_cmd` from `--explain` rather than carrying one of its own, so the command and the doctor can never disagree about how this project starts. Full contract: [the `--explain` convention](../../README.md#the---explain-contract).

## Not a replacement for JetBrains' own plugin

[`phpstorm-plugin@phpstorm-marketplace`](../../RECOMMENDED.md#-jetbrainsphpstorm-claude-marketplace) covers the PHP *language and project* domain — inspections-backed code review, Composer and environment detection, deprecation scans for a target PHP version. This plugin covers the *tooling surface*: how to drive the IDE, and the runtime debugger JetBrains ships nothing for. Run both.

---

Part of [cc-millz](../../README.md).
