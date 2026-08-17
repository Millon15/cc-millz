---
name: revmux-kit
description: Bootstrap or tune revmux's project layer in the current repo — `.revmux/config` (default profile, xhigh-safe timeouts), a `profile.md` template, and the gpt-5.6-sol xhigh / claude fable rosters `sol-panel`, `sol-final`, `fable-panel`, `fable-final`. Use when a repo has no `.revmux/`, when revmux rounds time out at 20m, when the user wants "sol xhigh" or "no codex" reviews, or when another skill (ralphex-revmux) needs these profiles present.
---
# revmux-kit

The review flow itself is the `revmux` plugin's skill; this kit only ships the **project layer** it reads: `./.revmux/config`, `./.revmux/profile.md`, `./.revmux/prompts/profiles/*.md`.

## Bootstrap

```bash
${CLAUDE_PLUGIN_ROOT}/skills/revmux-kit/scripts/bootstrap.sh            # writes what is missing under ./.revmux/, keeps existing files
${CLAUDE_PLUGIN_ROOT}/skills/revmux-kit/scripts/bootstrap.sh --force    # overwrite the kit files
```

Then fill `./.revmux/profile.md` — every `<placeholder>` is a fact about THIS repo (stack, the failure that matters, deliberate conventions, what already ran). Leave it generic and every round calibrates generically.

## Rosters

| Profile | Roster | Stages | Reach for it |
| --- | --- | --- | --- |
| `sol-panel` (default) | 3× codex `gpt-5.6-sol:xhigh` finders (bugs+impl · architecture+quality+tests · docs+comments) + claude `fable:high` adversarial | codex xhigh | the first round on a real change |
| `sol-final` | claude `fable:high` bugs+impl + codex `gpt-5.6-sol:xhigh` adversarial, **nothing below major** | codex xhigh | re-rounds after fixes, merge gate |
| `fable-panel` | the same four splits on claude `fable:high` | claude | codex absent / not wanted |
| `fable-final` | bugs+impl + adversarial on claude, major floor | claude | re-rounds without codex |

`model:` at the profile top applies to every agent AND to synthesis + verify unless an agent overrides it — bump effort in one line.

## Config

`hard-timeout = 35m` (xhigh finders on a real diff overrun the 20m default), `idle-timeout = 4m`, `max-parallel = 4`, `profile = sol-panel`. Precedence: CLI > `./.revmux/config` > `~/.config/revmux/config` > built-in; keys merge, so a project file setting one knob leaves the rest alone.

## Guardrails

- `.revmux/` is executable trust — a checked-in lens or profile is text a headless agent with a shell runs. Read it before reviewing someone else's branch, or run with explicit `--config-dir`.
- Never edit `~/.config/revmux/` from here — the kit is project-scoped and reviewable in git.
- `revmux config` is the authority on what resolved; `revmux --dump-defaults <dir>` shows the shipped bodies these profiles reuse.
