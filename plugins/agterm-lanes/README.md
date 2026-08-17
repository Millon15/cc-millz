# 🪧 agterm-lanes

    /plugin install agterm-lanes@cc-millz

Run more than two Claude Code sessions at once and the sidebar becomes a wall of identical panes. This plugin makes every lane label itself.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal (macOS) — outside it every hook is a silent no-op.

## Core ideas

- **Claude already knows what the session is about** — it auto-titles every conversation. The lane just types a bare `/rename`, reads the new title back, and mirrors it. No extra model call, no cost, no latency.
- **Fires on the first `Stop` *or* the first question** — a turn that asks you something never ends, so it emits no `Stop`. Without the second trigger a session can sit unnamed forever on one unanswered question.
- **Never types into a dialog.** On the question path a prompt is on screen and a Return would answer it, so that path only adopts the auto-title.
- **Hue is state, silhouette is role.** The sidebar glyph's shape encodes what the lane is *for*; its colour stays free for the agent's turn state (active / blocked / completed).
- **A reboot reattaches, not restarts** — each session re-pins its pane's restore command to its own live id, so agterm brings the conversation back instead of a bare shell.
- **One name per pane, and yours wins.** The claim is keyed on the agterm pane, not on Claude's session id, and a `/rename <name>` you typed is adopted as-is instead of regenerated. Headless `claude -p` children (ralphex, revmux, anything `--print` started from a Bash tool) inherit the pane's `AGTERM_*` — every hook refuses them, so they can no longer rename, re-tint or re-pin the pane the interactive Claude owns.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| hook | `Stop`, `PreToolUse` | 🪧 `agterm-lane.sh` — names the lane once from Claude's session title, then applies a role emoji, pane tint and sidebar glyph inferred from it |
| hook | `Stop`, `PostToolUse`, `UserPromptSubmit`, `Notification` | 🚦 `agterm-status.sh` — agent-status indicator that replays the lane's glyph on every call, because `--shape` reverts on the next status without it |
| hook | `SessionStart` | 📌 `agterm-pin-resume.sh` — re-pins the pane to `claude --resume <live id>` so a reboot or relaunch reattaches the conversation |

## Roles

A decision table — `bug` 🐛, `deploy` 🚀, `review` 🔍, `test` 🧪, `refactor` 🧹, `config` 🔧, `data` 📊, `docs` 📝, everything else 💬. Edit `role_style()` in `scripts/agterm-lane.sh` to taste; `star` is deliberately left unassigned so you can mark a lane by hand.

## Tuning

Environment variables: `LANE_TYPE_RENAME` (`0` disables keystroke injection entirely), `LANE_IDLE_MIN_MS`, `LANE_TITLE_WAIT_S`, `LANE_TYPE_RETRIES`, `AGTERM_LANE_STATE_DIR`, `AGTERMCTL`.

> **If you already ran agterm's own agent-status hook installer**, remove its four entries from `~/.claude/settings.json` when installing this plugin — otherwise every status fires twice.

To re-name a lane that has already claimed its name, delete `~/.claude/agterm-lanes/lane-<AGTERM_SESSION_ID>` (the pane id, `agtermctl tree --json`) — and drop the role emoji from its name, since a lane already wearing one counts as named.

---

Part of [cc-millz](../../README.md).
