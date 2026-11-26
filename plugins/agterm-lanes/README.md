# 🪧 agterm-lanes

    /plugin install agterm-lanes@cc-millz

Run more than two Claude Code sessions at once and the sidebar becomes a wall of identical panes. This plugin makes every lane label itself.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal (macOS) — outside it every hook is a silent no-op.

## Core ideas

- **Claude already knows what the session is about** — it auto-titles every conversation. The lane just types a bare `/rename`, reads the new title back, and mirrors it. No extra model call, no cost, no latency.
- **Fires on the first `Stop` *or* the first question** — a turn that asks you something never ends, so it emits no `Stop`. Without the second trigger a session can sit unnamed forever on one unanswered question.
- **Never types into a dialog.** On the question path a prompt is on screen and a Return would answer it, so that path only adopts the auto-title.
- **Status belongs to agterm, role belongs to the name.** The lane never writes agent status: agterm's own Claude adapter does, alone, so the glyph keeps the turn state (active / blocked / completed). Role shows as the emoji and the colour of the sidebar name.
- **A reboot reattaches, not restarts** — each session re-pins its pane's restore command to its own live id, so agterm brings the conversation back instead of a bare shell.
- **One name per pane, and yours wins.** The claim is keyed on the agterm pane, not on Claude's session id, and a `/rename <name>` you typed is adopted as-is instead of regenerated. Headless `claude -p` children (ralphex, revmux, anything `--print` started from a Bash tool) inherit the pane's `AGTERM_*` — every hook refuses them, so they can no longer rename, re-tint or re-pin the pane the interactive Claude owns.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| hook | `Stop`, `PreToolUse` | 🪧 `agterm-lane.sh` — names the lane once from Claude's session title, then applies a role emoji, pane tint and name colour inferred from it |
| hook | `SessionStart` | 📌 `agterm-pin-resume.sh` — re-pins the pane to `claude --resume <live id>` so a reboot or relaunch reattaches the conversation |

## Roles

A decision table — `bug` 🐛, `deploy` 🚀, `review` 🔍, `test` 🧪, `refactor` 🧹, `config` 🔧, `data` 📊, `docs` 📝, everything else 💬. Each role also sets a pane background tint and a sidebar name colour (`session tint <colour> --on name`). Edit `role_style()` in `scripts/agterm-lane.sh` to taste.

## Tuning

Environment variables: `LANE_TYPE_RENAME` (`0` disables keystroke injection entirely), `LANE_IDLE_MIN_MS`, `LANE_TITLE_WAIT_S`, `LANE_TYPE_RETRIES`, `AGTERM_LANE_STATE_DIR`, `AGTERMCTL`.

> **Agent status comes from agterm, not from this plugin.** Run agterm's **Help > Install Agent Status Hooks** once: it writes five Claude entries to `~/.claude/settings.json` (`UserPromptSubmit` and `PostToolUse` → `active --blink`, `Stop` → `completed --auto-reset`, `Notification` permission prompt and `PermissionRequest` → `blocked`). Up to v0.2.0 this plugin shipped its own status hooks; with both installed every status fired twice.

To re-name a lane that has already claimed its name, delete `~/.claude/agterm-lanes/lane-<AGTERM_SESSION_ID>` (the pane id, `agtermctl tree --json`) — and drop the role emoji from its name, since a lane already wearing one counts as named.

---

Part of [cc-millz](../../README.md).
