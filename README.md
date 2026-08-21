# cc-millz

Things that make [Claude Code](https://claude.ai/code) even better — my personal marketplace of independent plugins, by [Millon15](https://github.com/Millon15).

> Structure inspired by [umputun/cc-thingz](https://github.com/umputun/cc-thingz).

This is an unapologetically opinionated set: every plugin here is something I actually use. Even if you don't need my particular toolbox, it may give you ideas for building your own.

Provenance: several of these plugins were generalized out of a private codebase before landing here. Extracted from a private monorepo.

---

> ## 🌟 [Other people's plugins I actually use →](RECOMMENDED.md)
>
> Six third-party marketplaces worth a `/plugin marketplace add`: design dialogue, TUI diff annotation, autonomous execution, Codex, engineering skills, PhpStorm.
>
> Deliberately **not** re-exported here — install them upstream and keep their updates.

---

## 🔌 Plugins

| Plugin | Description |
|--------|-------------|
| [🪧 agterm-lanes](plugins/agterm-lanes/README.md) | Self-labelling agterm panes — name, emoji, tint, glyph and reboot-survivable sessions |
| [🤖 codex-delegation](plugins/codex-delegation/README.md) | Codex CLI (gpt-5.6/gpt-5.5) as a second-tier workforce under Claude's orchestration |
| [🧰 essentials](plugins/essentials/README.md) | General-purpose personal skills — code-style, concise-writing, `/e15`, `/tldr`, `/recall` |
| [🔀 merge-kit](plugins/merge-kit/README.md) | Conflict resolution and merge forensics for any repo — profile-driven, forge read from `origin`, nothing silently reverted. Extracted from a private monorepo. |
| [🐘 phpstorm](plugins/phpstorm/README.md) | PhpStorm MCP as an agent surface — code navigation, inspections, live Xdebug loop, and a doctor that tells three identical-looking debug misconfigurations apart. Extracted from a private monorepo. |
| [🔁 ralphex-revmux](plugins/ralphex-revmux/README.md) | revmux as ralphex's external reviewer — preflight, one-round-per-iteration glue, two-stage runner, post-run reporter + optimizer |
| [🧰 revmux-kit](plugins/revmux-kit/README.md) | revmux project layer — xhigh-safe config, profile.md template, `sol-*` / `fable-*` rosters |
| [🛡 security-audit](plugins/security-audit/README.md) | Pre-adoption audit of a repo, package, MCP server or raw script — nine adaptive phases, verdict banner, every tool optional |
| [🎬 short-video-reader](plugins/short-video-reader/README.md) | Read one short clip end-to-end from local artifacts — provenance, frames, contact sheets, captions, offline-only transcription; the scratch tree is a printed three-rung ladder and a delete needs the tool's own marker. Extracted from a private monorepo. |
| [📟 statusline](plugins/statusline/README.md) | Two-line status line — git scopes, context window, loaded skills and MCP, quota and spend |
| [🛠 toolsmith](plugins/toolsmith/README.md) | Author, review, retire and explain agent dev tools in any layout — the directories come from a layout adapter, the reuse search runs first, companion skills are soft. Extracted from a private monorepo. |
| [🪆 unslop-kit](plugins/unslop-kit/README.md) | My reply contract as a Russian doll over pstack's unslop — wording pass, then layout pass, loaded by a SessionStart hook |
| [🥔 pstack](https://github.com/cursor/plugins/tree/main/pstack) (mirror) | poteto's pstack, mirrored via `git-subdir` from `cursor/plugins` because upstream ships no Claude Code marketplace — 44 skills + 2 agents, Cursor-authored (model panels and `~/.cursor/rules` do not apply); required by unslop-kit |

Each plugin is independent: install only what you want, in any combination.

## 📦 Install

Add the marketplace, then install the plugins you want:

    /plugin marketplace add Millon15/cc-millz

    /plugin install essentials@cc-millz
    /plugin install codex-delegation@cc-millz

- **Test locally**: run `claude --plugin-dir plugins/codex-delegation`, and use `/reload-plugins` in-session to pick up file changes.
- **Or advertise them in a repo's versioned `.claude/settings.json`.** Pinning a plugin there does NOT install it: on the next session Claude Code reports it as not installed and prints the `claude plugin install` line for you to run. The one automatic install path is a plugin's own `dependencies` field, which installs the plugins it names alongside it:

```json
{
  "extraKnownMarketplaces": {
    "cc-millz": { "source": { "source": "github", "repo": "Millon15/cc-millz" } }
  },
  "enabledPlugins": { "codex-delegation@cc-millz": true }
}
```

## 🔄 Updating

- `/plugin` → **Marketplaces** → **Update marketplace** — the reliable path; pulls the latest catalog from the repository immediately.
- `/plugin` → **Installed** → **Update now** — uses a local cache that can be stale; treat it as a fallback after updating the marketplace.
- **Enable auto-update**: `/plugin` → Marketplaces → Enable auto-update refreshes the marketplace catalog on each session start.

## 🧭 Conventions

### The `--explain` contract

Every plugin that ships an entry script under `scripts/` resolves its project configuration the same way, and prints that resolution on demand. One shape, so the fifth plugin matches the first four without archaeology.

- **Invocation** — `scripts/<plugin>.sh --explain`. Read-only: it resolves, prints and exits, and touches nothing.
- **Profile** — a committed `.<plugin>.json` at the consuming project's root. Team-shared repo facts belong in version control, so nothing is prompted per user.
- **Exit codes** — `0` when the resolution succeeded, `2` when a profile exists but cannot be read or parsed. A malformed profile is never a silent fall-through to auto-detection.

Output is a single JSON object on stdout:

```json
{
  "plugin": "merge-kit",
  "profile_file": ".merge-kit.json",
  "values":  { "test_cmd": "npm test", "forge": "gh" },
  "sources": { "test_cmd": "profile",  "forge": "detected:origin-url" }
}
```

- `profile_file` is the resolved path, or `null` when no profile was found.
- Every key in `values` has the same key in `sources`. A value with no source is a bug.
- A source is one of three words: `profile` when the committed file supplied it, `detected:<signal>` when the tool worked it out and from what, `default` when neither applied and the tool fell back.
- When a tool can detect nothing and has no honest default, it exits with a usage message naming the markers it looked for. An unmarked directory is a usage error, not a default.

Tests assert both halves through the shared helper, `assert_explain_source <json> <key> <expected-source>`, so a value that is right for the wrong reason still fails.

## 🧪 Tests

The whole test surface is flat, at the repo root. A plugin install copies that plugin's directory out of the marketplace clone, so tests and fixtures parked under `plugins/<name>/` would be downloaded by every user of the plugin. At the root they stay in the repo and out of the install.

    tests/test-<plugin>-<suite>.bats     shell and command surfaces
    tests/test-<plugin>-<suite>.test.ts  TypeScript, run under bun test
    tests/fixtures/<plugin>/             fixtures, one directory per plugin
    tests/helpers/                       shared bats helpers

- `tests/helpers/common.bash` carries temp-directory setup and teardown, stub executables on `PATH`, git fixtures, and `assert_explain_source`.
- `make test` discovers and runs every suite of both kinds. `make test-bats` and `make test-ts` run one kind.
- CI runs the same two discovery sets on every push and pull request.
