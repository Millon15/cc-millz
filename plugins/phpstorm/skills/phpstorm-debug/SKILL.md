---
name: phpstorm-debug
description: >-
  Drive a live Xdebug session through PhpStorm's MCP debugger tools — set
  breakpoints, read the call stack and frame values, evaluate expressions, and
  mutate state mid-flight. Use when debugging a PHP bug interactively, inspecting
  what a variable actually holds at runtime, tracing which branch a request takes,
  or whenever you are about to add `dump()` / `var_dump()` / `error_log()` to
  source just to see a value.
---

# Xdebug via PhpStorm MCP

**Attach, don't launch.** The IDE's own launcher (`execute_run_configuration`,
`xdebug_start_debugger_session(configurationName=…)`) times out against Docker and
other remote interpreters. What works every time: arm a breakpoint, trigger the code
from **outside** the IDE, and attach to the connection it makes.

A breakpoint beats a `dump()` — no source edit, no cleanup pass, no stray debug
statement reaching a commit.

## Preflight

Three conditions gate everything. A miss in any one produces the same useless
symptom — *"Debug session was finished without being paused"* — so check all three
before blaming your breakpoint.

| Condition | Verify | Fix |
| --- | --- | --- |
| IDE is listening | `lsof -iTCP -sTCP:LISTEN -n -P +c 0` shows the Xdebug port | `invoke_ide_action(actionId="PhpListenDebugAction")` — toggles it |
| Server name is mapped | container's `PHP_IDE_CONFIG=serverName=X` matches an entry in `Settings │ PHP │ Servers` **with path mappings** | add the server + map each project dir to its container path |
| Force-break is off | `.idea/workspace.xml` → `PhpDebugGeneral` has `xdebug_force_break_when_no_path_mapping="false"` | uncheck both *Force break at first line…* boxes in `Settings │ PHP │ Debug` |

⚠️ Leaving force-break **on** while the runtime uses `xdebug.start_with_request=1`
suspends **every** PHP CLI process the moment it starts — every `docker exec … php`
hangs until it times out. Turning it off makes listening free; leave listening on.

Read the runtime's own view rather than trusting config files:

```bash
docker exec <container> php -r 'foreach(["xdebug.mode","xdebug.client_host","xdebug.client_port","xdebug.start_with_request"] as $k) printf("%-26s %s\n",$k,ini_get($k));'
```

## The loop

1. **Arm** — `xdebug_set_breakpoint(filePath, line)`. `filePath` is project-relative
   on the **host**; PhpStorm maps it to the container path.
2. **Clear the field** — `xdebug_list_breakpoints`. Any other enabled breakpoint the
   run passes through steals your pause. Disable or remove them, or set
   `breakpointsMuted` and re-enable only yours.
3. **Trigger externally, in the background** — `docker exec … php …`, `curl`, a test
   runner. **Never foreground**: the process suspends at the breakpoint and blocks
   your shell until it times out.
4. **Attach** — `xdebug_control_session(action="WAIT_FOR_PAUSE", sessionId, timeout)`.
   Returns a `frameValues` snapshot with the pause, so a trivial inspection needs no
   follow-up call.
5. **Inspect** — `xdebug_get_stack` → `xdebug_get_frame_values(depth)` →
   `xdebug_evaluate_expression` → `xdebug_get_value_by_path` for deep drills.
6. **Probe by mutation** — `xdebug_set_variable` rewrites a live value, so you can
   force the branch you need instead of hunting input that reaches it.
7. **Release** — `xdebug_control_session(action="STOP")`. Always. A leaked suspended
   session holds the worker process open.

## Session hygiene

- **`sessionId` is mandatory once a second session exists.** Background crons and
  incidental requests open their own sessions; every session-scoped call then fails
  with *"Multiple debug sessions active"*. Read the live list from
  `xdebug_get_debugger_status` — never reuse an ID after `STOP`.
- **`frameIndex` expires** on `RESUME`, any `STEP_*`, and `run_to_line`. Re-read
  `xdebug_get_stack` after each; a cached index silently reads the wrong frame.
- **Breakpoints you set become `owner="user"` after an IDE restart.** Removal
  defaults to `owner="agent"`, so post-restart cleanup needs `owner="user"` plus an
  explicit `filePath`+`line` — never a bare owner filter, which would wipe every
  breakpoint the human placed.
- **`breakpointErrorsTail` reports breakpoints from unrelated projects** as *"not
  mapped to any file path on server"*. Noise from other services' files, not a fault
  in the run you are debugging.

## Does not work with Xdebug

Confirmed empirically — reach for these and you burn turns on nothing.

| Feature | Reality |
| --- | --- |
| Logpoints (`logExpression` + `suspendPolicy="NONE"`) | The breakpoint fires, but `tracepointOutputsTail` stays **empty** — output draining is JVM-debugger-only. **Not** a `dump()` replacement; to log without stopping, still edit the source. |
| `hitCount` | Always `0`, even on the breakpoint you are paused at. Useless as a "was it reached" signal — infer reachability from the pause itself. |
| `execute_run_configuration` / `start_debugger_session(configurationName=…)` | Times out against remote interpreters. Trigger externally instead. |

`breakpointErrorsTail` **does** work despite the same JVM-only caveat in the tool
docs — invalid conditions and unmapped paths surface there, and it is the fastest
way to find out a path mapping is wrong.

## Conditional and one-shot breakpoints

- `condition` — a PHP expression; the breakpoint only fires when it is true. The way
  to catch iteration 4,000 of a loop without stepping there.
- `temporary=true` — removes itself after the first hit; no cleanup step.
- `xdebug_run_to_line(filePath, line)` — advance to a target without stepping through
  every intervening statement.

Invalid `condition` expressions fail **asynchronously** — they appear in
`breakpointErrorsTail`, not as an error on the call that set them.
