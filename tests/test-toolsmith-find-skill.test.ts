/**
 * tests/test-toolsmith-find-skill.test.ts
 *
 * Unit tests for the skill finder's pure halves — parsing, tokenizing, ranking,
 * dedupe, the tier collectors and the argument parser. The bats suite drives the
 * same engine through its CLI; this one reaches the functions the CLI composes,
 * where a scoring or parsing regression is one assertion instead of a fixture.
 *
 * The port from a single-layout project changed one thing throughout: the
 * project tier no longer knows any directory. `collectProject` and
 * `readStagedPaths` take a resolved Layout, and `resolveLayout` asks the shipped
 * adapter — so the tests below build layouts explicitly and drive the adapter
 * against real marker directories rather than assuming a source directory name.
 */

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  collectCatalog,
  collectProject,
  collectUser,
  dedupe,
  exactNameCandidates,
  type Hit,
  type Layout,
  matchesExactName,
  normaliseExactName,
  parseArgs,
  parseFrontmatter,
  parseSkillsShResponse,
  rank,
  readEnabledPlugins,
  readStagedPaths,
  resolveLayout,
  tokenize,
} from "../plugins/toolsmith/scripts/find-skill";

const TMP = mkdtempSync(join(tmpdir(), "toolsmith-find-skill-"));

function fixture(name: string): string {
  const dir = join(TMP, name);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  return dir;
}

function write(path: string, body: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, body);
}

function hit(partial: Partial<Hit>): Hit {
  return {
    name: "x",
    kind: "skill",
    tier: "project",
    origin: "o",
    status: "",
    description: "",
    tags: [],
    score: 0,
    ...partial,
  };
}

/** A rulesync-shaped layout rooted at `root`, as the adapter would report it. */
function generatedLayout(root: string): Layout {
  return {
    layout: "rulesync",
    root,
    skillsDir: ".rulesync/skills",
    commandsDir: ".rulesync/commands",
    agentsDir: ".rulesync/subagents",
    rulesDir: ".rulesync/rules",
    stagedRegistry: ".rulesync/.staged-plugins.json",
  };
}

describe("parseFrontmatter", () => {
  test("reads name, inline description and list tags", () => {
    const fm = parseFrontmatter(
      [
        "---",
        "name: my-skill",
        "description: Use when testing things",
        "tags:",
        "  - alpha",
        "  - beta",
        "---",
        "# Body",
      ].join("\n"),
    );
    expect(fm.name).toBe("my-skill");
    expect(fm.description).toBe("Use when testing things");
    expect(fm.tags).toEqual(["alpha", "beta"]);
    expect(fm.disableModelInvocation).toBe(false);
  });

  test("folds a >- block description into one line", () => {
    const fm = parseFrontmatter(
      [
        "---",
        "name: agenty",
        "description: >-",
        "    First half of the sentence",
        "    and the second half",
        "---",
      ].join("\n"),
    );
    expect(fm.description).toBe(
      "First half of the sentence and the second half",
    );
  });

  test("detects disable-model-invocation", () => {
    const fm = parseFrontmatter(
      ["---", "name: manual", "disable-model-invocation: true", "---"].join(
        "\n",
      ),
    );
    expect(fm.disableModelInvocation).toBe(true);
  });

  test("survives a file with no frontmatter", () => {
    expect(parseFrontmatter("# Just a heading\n").name).toBeUndefined();
  });

  test("strips quotes from a quoted description", () => {
    expect(
      parseFrontmatter(["---", 'description: "Quoted text"', "---"].join("\n"))
        .description,
    ).toBe("Quoted text");
  });
});

describe("tokenize", () => {
  test("drops stopwords and single characters", () => {
    expect(tokenize("Use when you want a redis query")).toEqual([
      "want",
      "redis",
      "query",
    ]);
  });
});

describe("rank", () => {
  test("orders a name match above a description-only match", () => {
    const hits = [
      hit({ name: "unrelated", description: "mentions redis once" }),
      hit({ name: "redis-tuning", description: "nothing else" }),
    ];
    expect(rank(hits, "redis")[0].name).toBe("redis-tuning");
  });

  test("drops zero-score hits", () => {
    expect(
      rank([hit({ name: "alpha", description: "beta" })], "gamma"),
    ).toEqual([]);
  });

  test("boosts a known upstream source", () => {
    const known = hit({
      name: "pdf",
      origin: "anthropics/skills",
      tier: "remote",
    });
    const unknown = hit({
      name: "pdf",
      origin: "randomuser/stuff",
      tier: "remote",
    });
    expect(rank([unknown, known], "pdf")[0].origin).toBe("anthropics/skills");
  });
});

describe("dedupe", () => {
  test("keeps the richer of two rows describing the same plugin", () => {
    const thin = hit({
      name: "redis",
      origin: "redis@official",
      tier: "marketplace",
      description: "short",
    });
    const rich = hit({
      name: "redis",
      origin: "redis@official",
      tier: "marketplace",
      description: "a much longer blurb",
      installs: 3240,
    });
    const out = dedupe([thin, rich]);
    expect(out).toHaveLength(1);
    expect(out[0].installs).toBe(3240);
  });

  test("keeps rows that differ by tier", () => {
    expect(
      dedupe([
        hit({ name: "a", origin: "o", tier: "project" }),
        hit({ name: "a", origin: "o", tier: "installed" }),
      ]),
    ).toHaveLength(2);
  });
});

describe("resolveLayout", () => {
  test("an agent-config marker resolves to the plain layout and its dirs", () => {
    const root = fixture("marked");
    write(join(root, "AGENTS.md"), "# Agents\n");
    const { layout } = resolveLayout(root);
    expect(layout?.layout).toBe("plain");
    expect(layout?.skillsDir).toBe(".claude/skills");
    expect(layout?.stagedRegistry).toBeNull();
  });

  test("a plugin manifest resolves to the shipped dirs, with no rules layer", () => {
    const root = fixture("manifest");
    write(
      join(root, ".claude-plugin", "plugin.json"),
      JSON.stringify({ name: "toy", version: "0.1.0" }),
    );
    const { layout } = resolveLayout(root);
    expect(layout?.layout).toBe("plugin");
    expect(layout?.skillsDir).toBe("skills");
    expect(layout?.rulesDir).toBeNull();
  });

  test("an unmarked directory drops the tier with a note instead of guessing", () => {
    // Nothing above a fresh temp directory carries a marker, so the walk
    // reaches the filesystem root and the adapter exits 2.
    const { layout, note } = resolveLayout(fixture("unmarked"));
    expect(layout).toBeNull();
    expect(note).toContain("project tier skipped");
  });
});

describe("readStagedPaths", () => {
  test("reads the {staged: [...]} registry the layout names", () => {
    const root = fixture("staged");
    write(
      join(root, ".rulesync", ".staged-plugins.json"),
      JSON.stringify({ staged: [".rulesync/skills/tdd"] }),
    );
    const { staged, applicable } = readStagedPaths(generatedLayout(root));
    expect(applicable).toBe(true);
    expect(staged.has(".rulesync/skills/tdd")).toBe(true);
  });

  test("a layout with no registry is NOT APPLICABLE, which is not the same as empty", () => {
    const root = fixture("no-registry");
    const layout = { ...generatedLayout(root), stagedRegistry: null };
    const { staged, applicable } = readStagedPaths(layout);
    expect(applicable).toBe(false);
    expect(staged.size).toBe(0);
  });

  test("a malformed registry costs the staged flag, never a throw", () => {
    const root = fixture("staged-broken");
    write(join(root, ".rulesync", ".staged-plugins.json"), "{ not json");
    expect(readStagedPaths(generatedLayout(root)).staged.size).toBe(0);
  });
});

describe("collectProject", () => {
  test("collects every layer the layout declares and flags the staged ones", () => {
    const root = fixture("project");
    write(
      join(root, ".rulesync", "skills", "mine", "SKILL.md"),
      "---\nname: mine\ndescription: Use when local\n---\n",
    );
    write(
      join(root, ".rulesync", "skills", "borrowed", "SKILL.md"),
      "---\nname: borrowed\ndescription: from a plugin\n---\n",
    );
    write(
      join(root, ".rulesync", "commands", "grp", "cmd.md"),
      "---\ndescription: a command\n---\n",
    );
    write(
      join(root, ".rulesync", "subagents", "bot.md"),
      "---\nname: bot\ndescription: an agent\n---\n",
    );
    write(
      join(root, ".rulesync", "rules", "law.md"),
      "---\ndescription: a rule\n---\n",
    );
    write(
      join(root, ".rulesync", ".staged-plugins.json"),
      JSON.stringify({ staged: [".rulesync/skills/borrowed"] }),
    );

    const hits = collectProject(generatedLayout(root));
    expect(hits.map((h) => h.name).sort()).toEqual([
      "borrowed",
      "bot",
      "cmd",
      "law",
      "mine",
    ]);
    expect(hits.find((h) => h.name === "borrowed")?.status).toBe("staged");
    expect(hits.find((h) => h.name === "mine")?.status).toBe("");
    expect(hits.find((h) => h.name === "cmd")?.kind).toBe("command");
    expect(hits.find((h) => h.name === "law")?.kind).toBe("rule");
  });

  test("the SAME tree read through another layout's dirs yields nothing", () => {
    // The whole point of the adapter: the directories are the layout's, and
    // a finder that kept one hard-coded source dir would answer here too.
    const root = fixture("project-other-layout");
    write(
      join(root, ".rulesync", "skills", "mine", "SKILL.md"),
      "---\nname: mine\ndescription: Use when local\n---\n",
    );
    const plain: Layout = {
      layout: "plain",
      root,
      skillsDir: ".claude/skills",
      commandsDir: ".claude/commands",
      agentsDir: ".claude/agents",
      rulesDir: ".claude/rules",
      stagedRegistry: null,
    };
    expect(collectProject(plain)).toEqual([]);
  });

  test("a layer the layout does not have is skipped, not searched for", () => {
    const root = fixture("project-no-rules");
    write(join(root, "rules", "law.md"), "---\ndescription: a rule\n---\n");
    write(
      join(root, "skills", "packer", "SKILL.md"),
      "---\nname: packer\ndescription: Use when packing\n---\n",
    );
    const pluginLayout: Layout = {
      layout: "plugin",
      root,
      skillsDir: "skills",
      commandsDir: "commands",
      agentsDir: "agents",
      rulesDir: null,
      stagedRegistry: null,
    };
    expect(collectProject(pluginLayout).map((h) => h.name)).toEqual(["packer"]);
  });

  test("returns an empty list when the layout's dirs do not exist", () => {
    expect(collectProject(generatedLayout(fixture("empty-project")))).toEqual(
      [],
    );
  });
});

describe("collectUser", () => {
  test("marks a user skill carrying disable-model-invocation as locked", () => {
    const home = fixture("home");
    write(
      join(home, ".claude", "skills", "solo", "SKILL.md"),
      "---\nname: solo\ndescription: manual only\ndisable-model-invocation: true\n---\n",
    );
    const hits = collectUser(home);
    expect(hits).toHaveLength(1);
    expect(hits[0].status).toContain("locked");
    expect(hits[0].tier).toBe("user");
  });
});

describe("readEnabledPlugins", () => {
  test("project settings win over user settings", () => {
    const root = fixture("enabled-root");
    const home = fixture("enabled-home");
    write(
      join(home, ".claude", "settings.json"),
      JSON.stringify({ enabledPlugins: { "p@m": true, "q@m": true } }),
    );
    write(
      join(root, ".claude", "settings.json"),
      JSON.stringify({ enabledPlugins: { "p@m": true } }),
    );
    const enabled = readEnabledPlugins(root, home);
    expect(enabled.get("p@m")).toBe("project");
    expect(enabled.get("q@m")).toBe("user");
  });

  test("a broken settings.json does not throw", () => {
    const root = fixture("enabled-broken");
    write(join(root, ".claude", "settings.json"), "{oops");
    expect(readEnabledPlugins(root, fixture("enabled-home2")).size).toBe(0);
  });
});

describe("collectCatalog", () => {
  test("reads installs and always-on token cost, skipping installed plugins", () => {
    const home = fixture("catalog");
    write(
      join(home, ".claude", "plugins", "plugin-catalog-cache.json"),
      JSON.stringify({
        catalog: {
          plugins: {
            "keep@mkt": {
              plugin: "keep",
              unique_installs: 1200,
              tokens: { "claude-opus-4-7": { always_on: 693 } },
              components: { skills: [{ name: "alpha" }] },
              marketplace_entry: {
                description: "a catalog plugin",
              },
            },
            "skip@mkt": {
              plugin: "skip",
              marketplace_entry: {
                description: "already installed",
              },
            },
          },
        },
      }),
    );
    const hits = collectCatalog(home, new Set(["skip@mkt"]));
    expect(hits).toHaveLength(1);
    expect(hits[0].name).toBe("keep");
    expect(hits[0].installs).toBe(1200);
    expect(hits[0].alwaysOnTokens).toBe(693);
    expect(hits[0].tags).toEqual(["alpha"]);
  });

  test("a missing catalog cache degrades to no rows", () => {
    expect(collectCatalog(fixture("no-catalog"), new Set())).toEqual([]);
  });
});

describe("parseSkillsShResponse", () => {
  test("maps the documented payload", () => {
    const hits = parseSkillsShResponse({
      skills: [
        {
          id: "acme/database-skills/redis",
          skillId: "redis",
          name: "redis",
          installs: 7100,
          source: "acme/database-skills",
        },
      ],
    });
    expect(hits).toHaveLength(1);
    expect(hits[0].tier).toBe("remote");
    expect(hits[0].installs).toBe(7100);
    expect(hits[0].url).toBe("https://skills.sh/acme/database-skills/redis");
  });

  test("tolerates a reshaped payload", () => {
    expect(parseSkillsShResponse({ unexpected: true })).toEqual([]);
    expect(parseSkillsShResponse(null)).toEqual([]);
  });
});

describe("the exact-name collision check", () => {
  test("a declared name loses its slash and its category prefix", () => {
    expect(normaliseExactName("/man")).toBe("man");
    expect(normaliseExactName("/toolsmith:create")).toBe("create");
    expect(normaliseExactName("  /Group:Name  ")).toBe("name");
  });

  test("a hit answers to its declared name, its bare form and its file name", () => {
    expect(
      exactNameCandidates({
        name: "/toolsmith:create",
        basename: "dev-tool",
      }).sort(),
    ).toEqual(["/toolsmith:create", "create", "dev-tool"]);
  });

  test("a bare needle still clashes with a name written the way it is invoked", () => {
    const declared = { name: "/man", basename: "manual" };
    expect(matchesExactName(declared, "man")).toBe(true);
    expect(matchesExactName(declared, "manual")).toBe(true);
    expect(matchesExactName(declared, "/other:man")).toBe(true);
    expect(matchesExactName(declared, "nothing-declares-this")).toBe(false);
  });
});

describe("parseArgs", () => {
  test("defaults to the four local tiers with remote off", () => {
    const options = parseArgs(["redis", "query"]);
    expect(options?.query).toBe("redis query");
    expect(options?.remote).toBe(false);
    expect(options?.tiers).toEqual([
      "project",
      "user",
      "installed",
      "marketplace",
    ]);
  });

  test("--remote appends the remote tier", () => {
    expect(parseArgs(["x", "--remote"])?.tiers).toContain("remote");
  });

  test("--no-remote wins over --remote", () => {
    expect(parseArgs(["x", "--remote", "--no-remote"])?.tiers).not.toContain(
      "remote",
    );
  });

  test("--root overrides the working directory", () => {
    expect(parseArgs(["x", "--root", "/somewhere"])?.root).toBe("/somewhere");
  });

  test("--exact needs no query", () => {
    expect(parseArgs(["--exact", "tdd"])?.exact).toBe("tdd");
  });

  test("rejects an empty invocation and an unknown flag", () => {
    expect(parseArgs([])).toBeNull();
    expect(parseArgs(["x", "--bogus"])).toBeNull();
  });

  test("clamps a nonsense --limit to the default", () => {
    expect(parseArgs(["x", "--limit", "0"])?.limit).toBe(8);
  });
});
