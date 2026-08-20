# 🪆 unslop-kit

    /plugin install pstack@cc-millz
    /plugin install review@umputun-cc-thingz
    /plugin install unslop-kit@cc-millz

My reply contract as a Russian doll over [poteto's unslop](https://github.com/cursor/plugins/tree/main/pstack/skills/unslop) and [umputun's writing-style](https://github.com/umputun/cc-thingz): pass 1 cuts the AI tells from the wording, pass 2 pins every claim to an exact reference and a flat verdict, pass 3 lays the reply out my way. A SessionStart hook loads the skill in every session, so nothing has to remember to call it. Personal taste — install at user scope.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `unslop-kit:unslop-formatting` | 🪆 Pass 1 `pstack:unslop` (31 patterns + self-audit, abridged fallback when pstack is missing; the "add soul" step scoped to chat and prose), pass 2 `review:writing-style` (exact path:line/PR/commit references, identities for findings, verdict over feeling, first-person corrections, named uncertainty; its User Override Check voided, checklist fallback when the review plugin is missing), then pass 3 the figure-paragraph skeleton with five explicit unslop overrides — English Check first, TL;DR, then per paragraph: one emoji bold claim line, ≤2 prose sentences, ≤1 small numeric table, ≥1 italic caption above an ASCII/mermaid visual, a 2-7 line `▎` receipt ledger, `---` separators (NO nested lists), `[ASSUMPTION]` markers, the CLI rendering rules (everything block-level at column zero, verified in the TUI), a send-check |
| hook | `SessionStart` | 🔔 `scripts/session-start-unslop.sh` injects the directive on startup, resume, clear and compact: all three Skill calls in one batch, each inner call gated on its plugin being in `installed_plugins.json`, a one-time "fallback in force" note when one is not. Strictly OPT-IN: silent unless `~/.claude/unslop-kit.mode` holds `1` or `UNSLOP_HOOK=1` is exported (interactive sessions only — headless/SDK runs, `CLAUDE_CODE_ENTRYPOINT=sdk-*` like `claude -p` and ralphex/revmux workers, stay silent; the contract formats human-facing text only) or `UNSLOP_HOOK=force` (everywhere, for A/B runs). Installing the plugin alone never changes a session |

## How the doll nests

- 🔔 **Hook.** Fires on every SessionStart source and tells Claude to load `unslop-kit:unslop-formatting`, `pstack:unslop` AND `review:writing-style` in one batch, now and again after compaction. Naming only the wrapper left the inner skill unloaded (seen 2026-08-19), so the hook names all three and checks each install itself.
- 🪆 **unslop-formatting.** Opens with gates (no visible inner Skill call in this context window = call it now), runs pstack then writing-style over the draft, then applies the layout. Chat replies get all three passes; commits, PR bodies, comments, docs and Slack/Jira bodies get passes 1 and 2 only.
- 🧹 **pstack:unslop.** The upstream wording skill, untouched, from `pstack@cc-millz` (mirrored via `git-subdir` from `cursor/plugins`).
- 🎯 **review:writing-style.** The upstream precision skill, untouched, from `review@umputun-cc-thingz`. unslop-formatting voids its User Override Check (this kit IS the user's rule) and names which sections apply; on conflict the ranking is layout > writing-style > unslop.

## Requires

- `pstack@cc-millz` for pass 1. Without it the skill runs an abridged checklist and says so once.
- `review@umputun-cc-thingz` for pass 2. Without it the skill runs its precision checklist and says so once.
- `jq` on PATH for the hook.

## Opt in

Installing the plugin does nothing by itself. Turn it on per user with the marker file:

    echo 1 > ~/.claude/unslop-kit.mode

`1` covers interactive sessions only; headless/SDK runs are always skipped. Delete the file (or write `0`) to opt out. A `UNSLOP_HOOK` shell export overrides the marker per run. Do NOT use a settings.json `env` block for this: it never reaches hook processes, and declaring `UNSLOP_HOOK` there even strips a shell export from the hook's env (observed 2026-08-20 on CLI 2.1.235).

## Test locally

    UNSLOP_HOOK=force claude --plugin-dir plugins/unslop-kit -p "describe this repo in one paragraph"

Compare with `UNSLOP_HOOK` unset on the same prompt.

---

Part of [cc-millz](../../README.md).
