# 🧰 revmux-kit

    /plugin install revmux-kit@cc-millz

Drops a ready project layer for [revmux](https://github.com/umputun/revmux) into any repo: a `.revmux/config` with xhigh-safe timeouts, a `profile.md` template to fill with the repo's own facts, and four rosters built around gpt-5.6-sol xhigh and claude fable.

⚠️ **Depends on** the `revmux` CLI (`brew install umputun/apps/revmux`) and, for the review flow itself, the revmux Claude Code plugin — this kit only ships configuration.

## Core ideas

- **Project layer, not user layer** — everything lands under `./.revmux/`, versioned with the repo, so a round is reproducible by anyone who clones it.
- **One `model:` line rules effort** — every roster sets `codex/gpt-5.6-sol:xhigh` (or `claude/fable:high`) at the top; agents and the synthesis/verify stages inherit it.
- **Panel then final** — `sol-panel` for the first round, `sol-final` (major floor) for every re-round; `fable-*` twins for machines without codex.

## Components

| Component | Trigger | Description |
|-----------|---------|-------------|
| skill | `revmux-kit:revmux-kit` | 🧰 Bootstrap + roster reference — `scripts/bootstrap.sh` materializes config, profile.md and the four profiles without overwriting; the skill explains which roster fits which round |

---

Part of [cc-millz](../../README.md).
