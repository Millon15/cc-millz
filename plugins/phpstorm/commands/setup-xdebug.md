---
description: >
  Get interactive PHP debugging working end-to-end against PhpStorm and Xdebug.
  Diagnoses every check through the project's own service profile, walks the
  fixes that need a human in the IDE, and re-verifies until green. Use when
  debugging is not working locally, or when onboarding a developer to it.
argument-hint: [service]
---

# `/phpstorm:setup-xdebug`

`${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh` owns every check and prints the exact fix per failure; this command drives it, walks the fixes that need a human in the IDE, and re-verifies until green.

Three unrelated misconfigurations all produce the same symptom — *"Debug session was finished without being paused"*. Never guess which one is live: run the doctor.

## Phase 0 — Resolve the project profile (ALWAYS FIRST)

Nothing below names a service, a container or a start command. Run the entry script and consume its JSON:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh" --explain
```

| JSON key | What it decides |
| --- | --- |
| `values.services` | the service names this project declares — the only valid `[service]` arguments, and the containers, ports, server names and path mappings behind them |
| `values.start_cmd` | the command that brings a stopped service up (Phase 2, step 1). `{service}` in it is replaced with the service name |
| `values.workspace_file` | the IDE settings file the debug-flag and path-mapping checks read |
| `sources.<key>` | `profile`, `detected:<signal>` or `default` — quoted verbatim when reporting |

- Exit 2 means there is no readable `.xdebug-doctor.json` at the project root. STOP and print the script's own message; it names the marker it looked for and the shape to write. NEVER continue on a guess, and NEVER invent service names.

Announce one resolution line before touching anything:

```
profile: {profile_file|none} · services {names} · start `{start_cmd}` ({sources.start_cmd})
```

## Input

Parse `$ARGUMENTS` for an optional service name. It MUST be one of the keys of `values.services`; anything else the doctor rejects with exit 2 rather than skipping every check. Omitted = check every declared service.

## Phase 1 — Diagnose

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/xdebug-doctor.sh" [service]`.
2. Exit 0 → skip to Phase 3.
3. Otherwise collect the `✗` lines. Each carries its own `↳ fix:` — those are the source of truth for what to tell the user. Do NOT invent fixes.

## Phase 2 — Repair

Apply in this order; cheapest and most common first. Re-run the doctor after each group rather than batching blindly.

1. **Containers down** → run the `values.start_cmd` from Phase 0, with `{service}` replaced by the service name the doctor flagged, wait for healthy, re-run. The doctor prints the same rendered command as its own `↳ fix:` — the two never disagree, because both read the one profile key.
2. **IDE not listening** → `invoke_ide_action(actionId="PhpListenDebugAction")` via the PhpStorm MCP server, or tell the user to click the phone icon. Does NOT survive an IDE restart — re-arm each session.
3. **Force-break enabled** (HARD GATE — fix before anything else in the IDE) → `Settings │ PHP │ Debug` → Xdebug section → uncheck *Force break at first line when no path mapping specified* AND *… when a script is outside the project*. While either is on, every `docker exec … php` hangs until timeout.
4. **Server missing / mapping missing** → `Settings │ PHP │ Servers`. Create the server with `Name` AND `Host` both set to the exact `serverName` the doctor reported, port `80`, debugger `Xdebug`, tick **Use path mappings**, then add each mapping the doctor listed. Click **OK**, not Apply, so it flushes to disk.
5. Re-run the doctor. Repeat until exit 0.

## Phase 3 — Prove it

Config passing is not proof a breakpoint fires. Run one real pause:

1. `xdebug_set_breakpoint` on a line that a known-cheap code path reaches.
2. `xdebug_list_breakpoints` — confirm no unrelated enabled breakpoint sits earlier on that path.
3. Trigger it in the **background** (`docker exec …`); a foreground trigger blocks until timeout once it suspends.
4. `xdebug_control_session(action="WAIT_FOR_PAUSE", sessionId)` → expect `paused` with frame values.
5. `xdebug_control_session(action="STOP")`, then remove the breakpoint with `owner="user"` plus explicit `filePath`+`line`.

Report the paused location and one real frame value as the evidence. The `phpstorm:phpstorm-debug` skill carries the full debugger loop.

## Guardrails

- MUST run `--explain` before anything else — every service name, container and start command in this run comes from it, never from memory.
- MUST re-run the doctor after every repair group — never declare success from an edit alone.
- MUST quote the doctor's own `↳ fix:` text; it encodes the resolved values.
- NEVER edit the IDE workspace file while PhpStorm is running — the IDE holds settings in memory and overwrites on exit.
- NEVER modify `.gitignore` to share the IDE config directory; per-developer setup is deliberate.
- NEVER remove breakpoints with a bare `owner` filter — it deletes every breakpoint the developer placed.
