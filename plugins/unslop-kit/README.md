# 🪆 unslop-kit

    /plugin install pstack@cc-millz
    /plugin install unslop-kit@cc-millz

My reply contract as a Russian doll over [poteto's unslop](https://github.com/cursor/plugins/tree/main/pstack/skills/unslop): pass 1 cuts the AI tells from the wording, pass 2 lays the reply out my way. A SessionStart hook loads the skill in every session, so nothing has to remember to call it. Personal taste — install at user scope.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `unslop-kit:unslop-millz` | 🪆 Pass 1 `pstack:unslop` (31 patterns + self-audit, abridged fallback when pstack is missing) with five explicit overrides, then pass 2 the reply skeleton — English Check first, TL;DR, nested bullets with one emoji glyph per top-level item, tables for comparisons, fenced code, `[ASSUMPTION]` markers, a send-check |
| hook | `SessionStart` | 🔔 `scripts/session-start-unslop.sh` injects the directive on startup, resume, clear and compact; `UNSLOP_HOOK=0` opts a session out |

## How the doll nests

- 🔔 **Hook.** Fires on every SessionStart source and tells Claude to load `unslop-kit:unslop-millz` now and again after compaction.
- 🪆 **unslop-millz.** Loads `pstack:unslop`, runs it over the draft, then applies the layout. Chat replies get both passes; commits, PR bodies, comments, docs and Slack/Jira bodies get pass 1 only.
- 🧹 **pstack:unslop.** The upstream skill, untouched, from `pstack@cc-millz` (mirrored via `git-subdir` from `cursor/plugins`).

## Requires

- `pstack@cc-millz` for pass 1. Without it the skill runs an abridged checklist and says so once.
- `jq` on PATH for the hook.

## Test locally

    UNSLOP_HOOK=1 claude --plugin-dir plugins/unslop-kit -p "describe this repo in one paragraph"

Compare with `UNSLOP_HOOK=0` on the same prompt.

---

Part of [cc-millz](../../README.md).
