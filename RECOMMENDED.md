# 🌟 Recommended

Other people's plugins I actually use. These are the marketplaces I add to every machine before I add my own.

**Nothing here is re-exported into `cc-millz` on purpose.** You install them from upstream, so you get their updates the day they ship, and issues and credit land with the people who actually wrote them.

Add a marketplace once, then install the plugins you want from it:

    /plugin marketplace add umputun/cc-thingz
    /plugin install planning@umputun-cc-thingz

| Marketplace | Add with | What it's for |
|-------------|----------|---------------|
| [🧠 cc-thingz](#-umputuncc-thingz) | `umputun/cc-thingz` | Design dialogue, planning, PR review, thinking tools |
| [🔍 revdiff](#-umputunrevdiff) | `umputun/revdiff` | Annotate diffs and documents inline in a TUI |
| [🔁 ralphex](#-umputunralphex) | `umputun/ralphex` | Autonomous plan execution with monitoring |
| [🤖 codex-plugin-cc](#-openaicodex-plugin-cc) | `openai/codex-plugin-cc` | Official Codex CLI integration — reviews and handoffs |
| [🎓 mattpocock/skills](#-mattpocockskills) | `mattpocock/skills` | Engineering workflow skills — TDD, review, domain modelling |
| [🐘 phpstorm-claude-marketplace](#-jetbrainsphpstorm-claude-marketplace) | `jetbrains/phpstorm-claude-marketplace` | JetBrains' own PHP skills, backed by IDE inspections |

## 🧠 [umputun/cc-thingz](https://github.com/umputun/cc-thingz)

    /plugin marketplace add umputun/cc-thingz

Seven independent plugins: `brainstorm`, `planning`, `review`, `thinking-tools`, `workflow`, `skill-eval`, `release-tools`.

This is the collaborative half of Claude Code — the part that stops the model from sprinting off in the wrong direction. `brainstorm` turns "build me X" into a real design dialogue, asking one question at a time and validating incrementally instead of dumping a finished answer you then have to argue with. `planning` writes a structured implementation plan you can read and correct before a single line is written. `review` carries a PR review flow plus a writing-style guide that strips AI-speak out of tickets and commit messages.

The sleeper is `skill-eval`: it forces a skill-relevance check before every response. That single hook is what makes the rest of your skill library actually fire instead of sitting unused.

The structure of this very marketplace is modelled on cc-thingz.

## 🔍 [umputun/revdiff](https://github.com/umputun/revdiff)

    /plugin marketplace add umputun/revdiff

Two plugins: `revdiff`, `revdiff-planning`.

Reviewing a diff by scrolling terminal output is miserable, and typing "the third hunk in that file, the null check" back to Claude is worse. revdiff opens a TUI overlay where you annotate hunks inline, then hands the annotations back so Claude addresses exactly the lines you marked.

It reads git, hg and jj repositories, and it is not limited to diffs — point it at a plain file or a document and you get the same annotation loop, which makes it a genuinely good way to review a plan or a spec. `revdiff-planning` wires that in automatically.

It needs a host it can draw an overlay in: tmux, zellij, ghostty, kitty, WezTerm, iTerm2, herdr, cmux or emacs-vterm.

## 🔁 [umputun/ralphex](https://github.com/umputun/ralphex)

    /plugin marketplace add umputun/ralphex

One plugin: `ralphex`.

An autonomous execution loop. Hand it a structured plan and it works through the tasks one by one, monitoring its own progress, until the plan is finished or it hits something it cannot resolve. It ships as a Go binary alongside the Claude-side skills (`ralphex`, `ralphex-plan`, `ralphex-adopt`, `ralphex-update`), so the loop survives independently of any one session.

Pairs naturally with `planning@umputun-cc-thingz`: write the plan with one, execute it with the other.

## 🤖 [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)

    /plugin marketplace add openai/codex-plugin-cc

One plugin: `codex`. Requires the `codex` CLI, then `/codex:setup`.

The official Codex integration — `/codex:review` and `/codex:adversarial-review` for a second opinion on a diff, and the `codex-rescue` agent for handing a stuck task to a different model family entirely. The value is not that one model is better; it is that two model families have different blind spots, and the one reviewing your code should not be the one that wrote it.

Pairs with [`codex-delegation@cc-millz`](plugins/codex-delegation/README.md), which depends on this plugin and adds a model-routing rubric and fan-out lanes on top. The official implementations always take precedence.

## 🎓 [mattpocock/skills](https://github.com/mattpocock/skills)

    /plugin marketplace add mattpocock/skills

One plugin, `mattpocock-skills`, carrying 30+ skills across engineering, productivity and misc.

The ones that earn their place: `tdd` (red-green-refactor with real integration tests), `code-review` (reviews a branch along a standards axis and a spec axis in parallel sub-agents, reported side by side), `domain-modeling`, `diagnosing-bugs`, `resolving-merge-conflicts`, and `grilling` / `grill-me` — a relentless design interview that keeps asking until the understanding is genuinely shared rather than assumed.

If you write skills yourself, `writing-great-skills` is the reference for doing it well. Note that it ships locked to user invocation, so the Skill tool refuses to load it autonomously until you unlock it.

## 🐘 [jetbrains/phpstorm-claude-marketplace](https://github.com/jetbrains/phpstorm-claude-marketplace)

    /plugin marketplace add jetbrains/phpstorm-claude-marketplace

One plugin: `phpstorm-plugin`. Requires PhpStorm with its MCP server enabled.

JetBrains' own PHP skills, and they are good precisely because they are backed by the IDE rather than by pattern matching: `php-code-review` runs the same inspection engine you see in the editor, `php-project-guide` detects your environment and Composer setup and carries Symfony and Laravel references, and `upgrade-php` scans for deprecations against a target version and applies fixes after confirmation.

A `PostToolUse` hook runs inspections after every PHP edit. It exits immediately on non-PHP files, so it costs nothing on the rest of your tree.

Pairs with [`phpstorm@cc-millz`](plugins/phpstorm/README.md) rather than competing with it — theirs covers the PHP language and project domain, mine covers the IDE tooling surface and the live Xdebug loop.
