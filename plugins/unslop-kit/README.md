# 🪆 unslop-kit

    /plugin install pstack@cc-millz
    /plugin install review@umputun-cc-thingz
    /plugin install unslop-kit@cc-millz

My reply contract as a Russian doll over [poteto's unslop](https://github.com/cursor/plugins/tree/main/pstack/skills/unslop) and [umputun's writing-style](https://github.com/umputun/cc-thingz): pass 1 cuts the AI tells from the wording, pass 2 pins every claim to an exact reference and a flat verdict, pass 3 lays the reply out my way. A SessionStart hook loads the skill in every session, so nothing has to remember to call it. Personal taste — install at user scope.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `unslop-kit:unslop-formatting` | 🪆 Pass 1 `pstack:unslop` (31 patterns + self-audit, abridged fallback when pstack is missing; the "add soul" step scoped to chat and prose), pass 2 `review:writing-style` (exact path:line/PR/commit references, identities for findings, verdict over feeling, first-person corrections, named uncertainty; its User Override Check voided, checklist fallback when the review plugin is missing), then pass 3 the reply skeleton with five explicit unslop overrides — English Check first, TL;DR, body as prose paragraphs with one emoji glyph and a bold verdict lead-in each (NO nested lists), tables for comparisons, fenced code, `[ASSUMPTION]` markers, the CLI rendering rules (tables and code blocks at top level only, verified in the TUI), a send-check |
| hook | `SessionStart` | 🔔 `scripts/session-start-unslop.sh` injects the directive on startup, resume, clear and compact: all three Skill calls in one batch, each inner call gated on its plugin being in `installed_plugins.json`, a one-time "fallback in force" note when one is not; `UNSLOP_HOOK=0` opts a session out |

## How the doll nests

- 🔔 **Hook.** Fires on every SessionStart source and tells Claude to load `unslop-kit:unslop-formatting`, `pstack:unslop` AND `review:writing-style` in one batch, now and again after compaction. Naming only the wrapper left the inner skill unloaded (seen 2026-08-19), so the hook names all three and checks each install itself.
- 🪆 **unslop-formatting.** Opens with gates (no visible inner Skill call in this context window = call it now), runs pstack then writing-style over the draft, then applies the layout. Chat replies get all three passes; commits, PR bodies, comments, docs and Slack/Jira bodies get passes 1 and 2 only.
- 🧹 **pstack:unslop.** The upstream wording skill, untouched, from `pstack@cc-millz` (mirrored via `git-subdir` from `cursor/plugins`).
- 🎯 **review:writing-style.** The upstream precision skill, untouched, from `review@umputun-cc-thingz`. unslop-formatting voids its User Override Check (this kit IS the user's rule) and names which sections apply; on conflict the ranking is layout > writing-style > unslop.

## Requires

- `pstack@cc-millz` for pass 1. Without it the skill runs an abridged checklist and says so once.
- `review@umputun-cc-thingz` for pass 2. Without it the skill runs its precision checklist and says so once.
- `jq` on PATH for the hook.

## Test locally

    UNSLOP_HOOK=1 claude --plugin-dir plugins/unslop-kit -p "describe this repo in one paragraph"

Compare with `UNSLOP_HOOK=0` on the same prompt.

---

Part of [cc-millz](../../README.md).
