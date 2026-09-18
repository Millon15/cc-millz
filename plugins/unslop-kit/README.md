# 🪆 unslop-kit

    /plugin install review@umputun-cc-thingz
    /plugin install unslop-kit@cc-millz

My reply contract as a Russian doll over a vendored copy of [poteto's unslop](https://github.com/cursor/plugins/tree/main/pstack/skills/unslop) and [umputun's writing-style](https://github.com/umputun/cc-thingz): pass 1 cuts the AI tells from the wording, pass 2 pins every claim to an exact reference and a flat verdict, pass 3 lays the reply out my way. A SessionStart hook loads the skill in every session, so nothing has to remember to call it. Personal taste — install at user scope.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `unslop-kit:unslop-formatting` | 🪆 Pass 1 `unslop-kit:unslop` (31 patterns + self-audit), pass 2 `review:writing-style` (exact path:line/PR/commit references, identities for findings, verdict over feeling, first-person corrections, named uncertainty; its User Override Check voided, checklist fallback when the review plugin is missing), then pass 3 the figure-paragraph skeleton with five explicit unslop overrides — English Check first, TL;DR, then per paragraph: one emoji bold claim line, ≤2 prose sentences, ≤1 small numeric table, ≥1 italic caption above a hand-drawn ASCII visual (branch rail, state rail, sequence rail, box map, bar, edge list; never mermaid source, the TUI prints it as text), a 2-7 line `>` receipt ledger, `---` separators (NO nested lists), every line hard-wrapped at 120 columns, `[ASSUMPTION]` markers, the CLI rendering rules (everything block-level at column zero, verified in the TUI), a send-check |
| skill | `unslop-kit:unslop` | 🧹 poteto's 31-pattern unslop body, vendored byte for byte and kept model-invocable (upstream `pstack:unslop` is `disable-model-invocation` since cursor/plugins PR #300). Pass 1 of the doll; also the pass any project outbound skill calls before a send |
| skill | `unslop-kit:human-brief` | 🧑 The shape of a send to a human colleague: a 1-2 line headline, at most 8 flat facts of at most 15 words with at most one link each, and every path, method name, query, timing, caveat or hedge moved into an optional "How to verify" block after them or into the ticket. Runs after the cut (`essentials:concise-writing` keeps every fact; this pass drops the ones that prove instead of conclude) and before the reword; a project outbound skill loads it as its shape step |
| script | `scripts/sync-unslop.sh` | 🔄 Re-vendors `skills/unslop/SKILL.md` from the installed `pstack@cc-millz` (or a path you pass), writes the provenance line with the upstream sha; `--check` exits 1 on drift, 2 when no source is found |
| hook | `SessionStart` | 🔔 `scripts/session-start-unslop.sh` injects the directive on startup, resume, clear and compact: all three Skill calls in one batch, the writing-style call gated on `review@umputun-cc-thingz` being in `installed_plugins.json`, a one-time "fallback in force" note when it is not. Strictly OPT-IN: silent unless `~/.claude/unslop-kit.mode` holds `1` or `UNSLOP_HOOK=1` is exported (interactive sessions only — headless/SDK runs, `CLAUDE_CODE_ENTRYPOINT=sdk-*` like `claude -p` and ralphex/revmux workers, stay silent; the contract formats human-facing text only) or `UNSLOP_HOOK=force` (everywhere, for A/B runs). Installing the plugin alone never changes a session |

## How the doll nests

- 🔔 **Hook.** Fires on every SessionStart source and tells Claude to load `unslop-kit:unslop-formatting`, `unslop-kit:unslop` AND `review:writing-style` in one batch, now and again after compaction. Naming only the wrapper left the inner skill unloaded (seen 2026-08-19), so the hook names all three and checks each install itself.
- 🪆 **unslop-formatting.** Opens with gates (no visible inner Skill call in this context window = call it now), runs unslop then writing-style over the draft, then applies the layout. Chat replies get all three passes; commits, PR bodies, comments, docs and Slack/Jira bodies get passes 1 and 2 only.
- 🧹 **unslop-kit:unslop.** poteto's unslop body, byte for byte, under a model-facing frontmatter. Upstream flagged its own copy `disable-model-invocation` (cursor/plugins PR #300, 2026-09-01), which drops `pstack:unslop` from the skill list and makes the Skill tool refuse it, so the kit ships the copy itself. `scripts/sync-unslop.sh` re-vendors it from the installed `pstack@cc-millz` (`--check` reports drift, exit 1); the provenance line under the frontmatter names the upstream sha.
- 🎯 **review:writing-style.** The upstream precision skill, untouched, from `review@umputun-cc-thingz`. unslop-formatting voids its User Override Check (this kit IS the user's rule) and names which sections apply; on conflict the ranking is layout > writing-style > unslop.

## Requires

- `pstack@cc-millz` only to re-run `scripts/sync-unslop.sh`; the vendored pass-1 skill works without it.
- `review@umputun-cc-thingz` for pass 2. Without it the skill runs its precision checklist and says so once.
- `jq` on PATH for the hook.

## Opt in

Installing the plugin does nothing by itself. Turn it on per user with the marker file:

    echo 1 > ~/.claude/unslop-kit.mode

`1` covers interactive sessions only; headless/SDK runs are always skipped. Delete the file (or write `0`) to opt out. A `UNSLOP_HOOK` shell export overrides the marker per run. Do NOT use a settings.json `env` block for this: it never reaches hook processes, and declaring `UNSLOP_HOOK` there even strips a shell export from the hook's env (observed 2026-08-20 on CLI 2.1.235).

## Re-vendor unslop

After `claude plugin update pstack@cc-millz`:

    bash plugins/unslop-kit/scripts/sync-unslop.sh --check   # exit 1 = behind upstream
    bash plugins/unslop-kit/scripts/sync-unslop.sh           # rewrite skills/unslop/SKILL.md

Then bump the plugin version and note the upstream sha (printed in the provenance line) in the changelog. Rule numbers 3-33 are stable upstream ids; a renumbering there breaks every skill that cites them.

## Test locally

    UNSLOP_HOOK=force claude --plugin-dir plugins/unslop-kit -p "describe this repo in one paragraph"

Compare with `UNSLOP_HOOK` unset on the same prompt.

---

Part of [cc-millz](../../README.md).
