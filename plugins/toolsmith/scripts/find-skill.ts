#!/usr/bin/env bun
/**
 * find-skill.ts — rank existing skills/commands/agents before authoring a new one.
 *
 * Five tiers, cheapest first:
 *   project     the layer dirs toolsmith.sh resolves for THIS project's layout
 *   user        ~/.claude/{skills,commands,agents}
 *   installed   ~/.claude/plugins/installed_plugins.json → each plugin's skills/commands/agents
 *   marketplace marketplace clones not installed + the official plugin catalog cache
 *   remote      skills.sh search API + `gh search code --filename SKILL.md`   (opt-in)
 *
 * The project tier owns no directory of its own: it asks the layout adapter and
 * walks what it is handed, so one binary answers in a generated-config project,
 * a plugin repo and a plain checkout alike. An unmarked directory simply has no
 * project tier — a note, not a failure, because the other four still answer and
 * for a collision check they are most of the answer.
 *
 * Usage:
 *   bun find-skill.ts <query...> [--root <dir>] [--tier a,b] [--remote] [--limit N] [--json]
 *   bun find-skill.ts --exact <name>
 *
 * Exit codes: 0 always (a no-hit run is an answer, not a failure); 2 on bad usage.
 */

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import type { Dirent } from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { discoverSkillDirs } from "./skill-dirs";

export type Kind = "skill" | "command" | "agent" | "rule" | "plugin";
export type Tier = "project" | "user" | "installed" | "marketplace" | "remote";

export interface Hit {
  name: string;
  /** The file (or skill dir) the hit came from — what a `/name` collision check must also match. */
  basename?: string;
  kind: Kind;
  tier: Tier;
  origin: string;
  status: string;
  description: string;
  tags: string[];
  installs?: number;
  alwaysOnTokens?: number;
  url?: string;
  score: number;
}

export interface Frontmatter {
  name?: string;
  description?: string;
  tags: string[];
  disableModelInvocation: boolean;
}

const ALL_TIERS: Tier[] = [
  "project",
  "user",
  "installed",
  "marketplace",
  "remote",
];
const LOCAL_TIERS: Tier[] = ["project", "user", "installed", "marketplace"];

const STOPWORDS = new Set([
  "a",
  "an",
  "and",
  "are",
  "as",
  "at",
  "be",
  "by",
  "for",
  "from",
  "how",
  "i",
  "in",
  "is",
  "it",
  "of",
  "on",
  "or",
  "that",
  "the",
  "this",
  "to",
  "use",
  "used",
  "using",
  "when",
  "with",
  "you",
  "your",
  "do",
  "does",
  "make",
  "new",
  "my",
  "we",
  "can",
  "should",
  "skill",
  "command",
  "agent",
]);

/** Repos whose skills are worth trusting first; mirrored by references/known-sources.json. */
export const KNOWN_SOURCES = [
  "anthropics/skills",
  "vercel-labs/agent-skills",
  "vercel-labs/skills",
  "obra/superpowers",
  "microsoft/skills",
  "microsoftdocs/agent-skills",
  "cursor/plugins",
  "openai/plugins",
  "mattpocock/skills",
  "umputun/cc-thingz",
  "Millon15/cc-millz",
  "upstash/context7",
  "planetscale/database-skills",
];

// ── frontmatter ────────────────────────────────────────────────────────────

/** Parse the YAML subset our layers actually use: name, description, tags, disable-model-invocation. */
export function parseFrontmatter(text: string): Frontmatter {
  const empty: Frontmatter = { tags: [], disableModelInvocation: false };
  if (!text.startsWith("---")) return empty;
  const end = text.indexOf("\n---", 3);
  if (end === -1) return empty;
  const lines = text.slice(4, end).split("\n");

  const out: Frontmatter = { tags: [], disableModelInvocation: false };
  let block: { key: string; indent: number } | null = null;
  const blockLines: string[] = [];

  const flush = () => {
    if (!block) return;
    const value = blockLines.join(" ").replace(/\s+/g, " ").trim();
    if (block.key === "description" && value) out.description = value;
    block = null;
    blockLines.length = 0;
  };

  for (const raw of lines) {
    const indent = raw.length - raw.trimStart().length;
    const line = raw.trim();

    if (block) {
      if (line === "" || indent > block.indent) {
        if (line !== "") blockLines.push(line);
        continue;
      }
      flush();
    }
    if (line === "" || line.startsWith("#")) continue;

    // list item under `tags:`
    if (line.startsWith("- ")) {
      if (out.tags.length || pendingList === "tags")
        out.tags.push(stripQuotes(line.slice(2)));
      continue;
    }

    const m = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(line);
    if (!m) continue;
    const [, key, rest] = m;
    pendingList = key;

    if (rest === ">-" || rest === ">" || rest === "|" || rest === "|-") {
      block = { key, indent };
      continue;
    }
    if (key === "name") out.name = stripQuotes(rest);
    else if (key === "description" && rest) out.description = stripQuotes(rest);
    else if (key === "tags") out.tags.push(...parseInlineList(rest));
    else if (key === "disable-model-invocation")
      out.disableModelInvocation = rest === "true";
  }
  flush();
  return out.name || out.description || out.tags.length
    ? out
    : { ...empty, ...out };
}

let pendingList = "";

function parseInlineList(rest: string): string[] {
  const trimmed = rest.trim();
  if (!trimmed.startsWith("[")) return [];
  return trimmed
    .slice(1, trimmed.endsWith("]") ? -1 : undefined)
    .split(",")
    .map((s) => stripQuotes(s.trim()))
    .filter(Boolean);
}

function stripQuotes(s: string): string {
  const t = s.trim();
  if (
    (t.startsWith('"') && t.endsWith('"')) ||
    (t.startsWith("'") && t.endsWith("'"))
  ) {
    return t.slice(1, -1);
  }
  return t;
}

// ── ranking ────────────────────────────────────────────────────────────────

export function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 1 && !STOPWORDS.has(t));
}

/** Lexical score: name hits weigh 3, tags 2, description 1, each scaled by the token's rarity. */
export function scoreHit(
  hit: Hit,
  queryTokens: string[],
  idf: Map<string, number>,
): number {
  const name = hit.name.toLowerCase();
  const nameTokens = new Set(tokenize(hit.name));
  const descTokens = new Set(tokenize(hit.description));
  const tagTokens = new Set(tokenize(hit.tags.join(" ")));

  let score = 0;
  for (const token of queryTokens) {
    const weight = idf.get(token) ?? 1;
    if (nameTokens.has(token) || name.includes(token)) score += 3 * weight;
    if (tagTokens.has(token)) score += 2 * weight;
    if (descTokens.has(token)) score += 1 * weight;
  }
  const joined = queryTokens.join(" ");
  if (joined && name === joined.replace(/ /g, "-")) score += 10;
  if (
    KNOWN_SOURCES.some((s) =>
      hit.origin.toLowerCase().startsWith(s.toLowerCase()),
    )
  )
    score += 2;
  if (hit.installs && hit.installs >= 1000) score += 2;
  return Math.round(score * 100) / 100;
}

export function rank(hits: Hit[], query: string): Hit[] {
  const queryTokens = tokenize(query);
  const df = new Map<string, number>();
  for (const hit of hits) {
    const seen = new Set([
      ...tokenize(hit.name),
      ...tokenize(hit.description),
      ...tokenize(hit.tags.join(" ")),
    ]);
    for (const token of seen) df.set(token, (df.get(token) ?? 0) + 1);
  }
  const total = Math.max(hits.length, 1);
  const idf = new Map<string, number>();
  for (const token of queryTokens) {
    idf.set(token, Math.log(1 + total / (1 + (df.get(token) ?? 0))));
  }
  for (const hit of hits) hit.score = scoreHit(hit, queryTokens, idf);
  return hits.filter((h) => h.score > 0).sort((a, b) => b.score - a.score);
}

// ── filesystem collectors ──────────────────────────────────────────────────

function readIfFile(path: string): string | null {
  try {
    return statSync(path).isFile() ? readFileSync(path, "utf8") : null;
  } catch {
    return null;
  }
}

function listDirs(dir: string): string[] {
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => join(dir, e.name));
  } catch {
    return [];
  }
}

function listMarkdown(dir: string, depth = 2): string[] {
  const out: string[] = [];
  const walk = (current: string, left: number) => {
    let entries: Dirent[];
    try {
      entries = readdirSync(current, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const path = join(current, entry.name);
      if (entry.isDirectory() && left > 0) walk(path, left - 1);
      else if (entry.isFile() && entry.name.endsWith(".md")) out.push(path);
    }
  };
  walk(dir, depth);
  return out;
}

function hitFromFile(
  path: string,
  kind: Kind,
  tier: Tier,
  origin: string,
  status: string,
): Hit | null {
  const text = readIfFile(path);
  if (text === null) return null;
  const fm = parseFrontmatter(text);
  const file =
    kind === "skill" ? basename(join(path, "..")) : basename(path, ".md");
  const flags = fm.disableModelInvocation
    ? [status, "locked"].filter(Boolean)
    : [status];
  return {
    name: fm.name ?? file,
    basename: file,
    kind,
    tier,
    origin,
    status: flags.filter(Boolean).join(" "),
    description: fm.description ?? "",
    tags: fm.tags,
    score: 0,
  };
}

function collectSkillDirs(
  skillsRoot: string,
  tier: Tier,
  origin: string,
  status: string,
): Hit[] {
  const hits: Hit[] = [];
  for (const dir of discoverSkillDirs(skillsRoot)) {
    const hit = hitFromFile(
      join(dir, "SKILL.md"),
      "skill",
      tier,
      origin,
      status,
    );
    if (hit) hits.push(hit);
  }
  return hits;
}

// ── the project tier, over the layout adapter ──────────────────────────────

/** The subset of `toolsmith.sh --explain` this tier walks. */
export interface Layout {
  layout: string;
  root: string;
  skillsDir: string;
  commandsDir: string;
  agentsDir: string | null;
  rulesDir: string | null;
  stagedRegistry: string | null;
}

/** Where the adapter lives — beside this file, whether installed or run from a checkout. */
export function adapterPath(): string {
  return join(dirname(fileURLToPath(import.meta.url)), "toolsmith.sh");
}

/**
 * Asks the adapter which layout this project has. A directory with no marker is
 * not an error here: the adapter exits 2, and the caller drops the project tier
 * and says so, rather than guessing a directory that would silently find nothing.
 */
export function resolveLayout(root: string): {
  layout: Layout | null;
  note?: string;
} {
  let raw: string;
  try {
    raw = execFileSync("bash", [adapterPath(), "--explain", "--root", root], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10000,
    });
  } catch (error) {
    const stderr = String(
      (error as { stderr?: unknown }).stderr ?? (error as Error).message,
    ).trim();
    return {
      layout: null,
      note: `project tier skipped — ${stderr.split("\n")[0]}`,
    };
  }
  try {
    const values = (JSON.parse(raw) as { values: Record<string, unknown> })
      .values;
    return {
      layout: {
        layout: String(values.layout),
        root: String(values.root),
        skillsDir: String(values.skills_dir),
        commandsDir: String(values.commands_dir),
        agentsDir: (values.agents_dir as string | null) ?? null,
        rulesDir: (values.rules_dir as string | null) ?? null,
        stagedRegistry: (values.staged_registry as string | null) ?? null,
      },
    };
  } catch {
    return {
      layout: null,
      note: "project tier skipped — adapter output is not JSON",
    };
  }
}

/**
 * The paths an enabled plugin stages into the sources, which are therefore not
 * authored here. Only a layout that generates its agent dirs keeps such a
 * registry; the other layouts report the tier as NOT APPLICABLE rather than as
 * empty, because "nothing is staged" and "nothing can be staged" differ.
 */
export function readStagedPaths(layout: Layout): {
  staged: Set<string>;
  applicable: boolean;
} {
  const staged = new Set<string>();
  if (!layout.stagedRegistry) return { staged, applicable: false };
  const registry = readIfFile(join(layout.root, layout.stagedRegistry));
  if (!registry) return { staged, applicable: false };
  try {
    const parsed = JSON.parse(registry) as { staged?: unknown[] } | unknown[];
    const list = Array.isArray(parsed) ? parsed : (parsed.staged ?? []);
    for (const path of list) if (typeof path === "string") staged.add(path);
  } catch {
    /* a malformed registry only costs the staged flag */
  }
  return { staged, applicable: true };
}

export function collectProject(layout: Layout): Hit[] {
  const { staged } = readStagedPaths(layout);
  const stagedFlag = (rel: string) => (staged.has(rel) ? "staged" : "");
  const under = (rel: string) => join(layout.root, rel);

  const hits: Hit[] = [];
  for (const dir of discoverSkillDirs(under(layout.skillsDir))) {
    const file = join(dir, "SKILL.md");
    if (!existsSync(file)) continue;
    const hit = hitFromFile(
      file,
      "skill",
      "project",
      layout.skillsDir,
      stagedFlag(`${layout.skillsDir}/${basename(dir)}`),
    );
    if (hit) hits.push(hit);
  }
  for (const file of listMarkdown(under(layout.commandsDir))) {
    const rel = `${layout.commandsDir}/${file.slice(under(layout.commandsDir).length + 1)}`;
    const hit = hitFromFile(
      file,
      "command",
      "project",
      layout.commandsDir,
      stagedFlag(rel),
    );
    if (hit) hits.push(hit);
  }
  if (layout.agentsDir) {
    for (const file of listMarkdown(under(layout.agentsDir), 0)) {
      const rel = `${layout.agentsDir}/${basename(file)}`;
      const hit = hitFromFile(
        file,
        "agent",
        "project",
        layout.agentsDir,
        stagedFlag(rel),
      );
      if (hit) hits.push(hit);
    }
  }
  if (layout.rulesDir) {
    for (const file of listMarkdown(under(layout.rulesDir), 0)) {
      const hit = hitFromFile(file, "rule", "project", layout.rulesDir, "");
      if (hit) hits.push(hit);
    }
  }
  return hits;
}

export function collectUser(home: string): Hit[] {
  const base = join(home, ".claude");
  const hits = collectSkillDirs(
    join(base, "skills"),
    "user",
    "~/.claude/skills",
    "",
  );
  for (const file of listMarkdown(join(base, "commands"))) {
    const hit = hitFromFile(file, "command", "user", "~/.claude/commands", "");
    if (hit) hits.push(hit);
  }
  for (const file of listMarkdown(join(base, "agents"), 0)) {
    const hit = hitFromFile(file, "agent", "user", "~/.claude/agents", "");
    if (hit) hits.push(hit);
  }
  return hits;
}

interface InstallRecord {
  scope?: string;
  projectPath?: string;
  installPath?: string;
}

export function readEnabledPlugins(
  root: string,
  home: string,
): Map<string, string> {
  const out = new Map<string, string>();
  for (const [file, label] of [
    [join(home, ".claude", "settings.json"), "user"],
    [join(root, ".claude", "settings.json"), "project"],
  ] as const) {
    const text = readIfFile(file);
    if (!text) continue;
    try {
      const enabled = (
        JSON.parse(text) as { enabledPlugins?: Record<string, boolean> }
      ).enabledPlugins;
      for (const [id, on] of Object.entries(enabled ?? {})) {
        if (on) out.set(id, label);
        else if (!out.has(id)) out.set(id, "disabled");
      }
    } catch {
      /* a hand-edited settings.json with a syntax error must not kill the search */
    }
  }
  return out;
}

export function collectInstalled(
  root: string,
  home: string,
): { hits: Hit[]; installed: Set<string> } {
  const installed = new Set<string>();
  const hits: Hit[] = [];
  const text = readIfFile(
    join(home, ".claude", "plugins", "installed_plugins.json"),
  );
  if (!text) return { hits, installed };

  let plugins: Record<string, InstallRecord[]>;
  try {
    plugins =
      (JSON.parse(text) as { plugins?: Record<string, InstallRecord[]> })
        .plugins ?? {};
  } catch {
    return { hits, installed };
  }
  const enabled = readEnabledPlugins(root, home);

  for (const [id, records] of Object.entries(plugins)) {
    installed.add(id);
    const record =
      records.find((r) => r.scope === "project" && r.projectPath === root) ??
      records.find((r) => r.scope === "user") ??
      records[0];
    const installPath = record?.installPath;
    if (!installPath || !existsSync(installPath)) continue;

    const state = enabled.get(id) ?? "installed-only";
    const status =
      state === "project"
        ? "enabled:project"
        : state === "user"
          ? "enabled:user"
          : state;
    hits.push(
      ...collectSkillDirs(join(installPath, "skills"), "installed", id, status),
    );
    for (const file of listMarkdown(join(installPath, "commands"))) {
      const hit = hitFromFile(file, "command", "installed", id, status);
      if (hit) hits.push(hit);
    }
    for (const file of listMarkdown(join(installPath, "agents"), 0)) {
      const hit = hitFromFile(file, "agent", "installed", id, status);
      if (hit) hits.push(hit);
    }
  }
  return { hits, installed };
}

interface MarketplaceEntry {
  name?: string;
  description?: string;
  source?: unknown;
}

export function collectMarketplace(
  home: string,
  installed: Set<string>,
): Hit[] {
  const hits: Hit[] = [];
  const root = join(home, ".claude", "plugins", "marketplaces");

  for (const clone of listDirs(root)) {
    const manifest = readIfFile(
      join(clone, ".claude-plugin", "marketplace.json"),
    );
    if (!manifest) continue;
    const marketplace = basename(clone);
    let entries: MarketplaceEntry[] = [];
    try {
      entries =
        (JSON.parse(manifest) as { plugins?: MarketplaceEntry[] }).plugins ??
        [];
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.name) continue;
      const id = `${entry.name}@${marketplace}`;
      if (installed.has(id)) continue;
      hits.push({
        name: entry.name,
        kind: "plugin",
        tier: "marketplace",
        origin: id,
        status: "not-installed",
        description: entry.description ?? "",
        tags: [],
        score: 0,
      });
      if (typeof entry.source === "string" && entry.source.startsWith("./")) {
        const dir = join(clone, entry.source.slice(2), "skills");
        hits.push(...collectSkillDirs(dir, "marketplace", id, "not-installed"));
      }
    }
  }
  hits.push(...collectCatalog(home, installed));
  return dedupe(hits);
}

/** The clone manifest and the catalog cache both describe the same plugin — keep the richer row. */
export function dedupe(hits: Hit[]): Hit[] {
  const byKey = new Map<string, Hit>();
  for (const hit of hits) {
    const key = `${hit.tier}:${hit.kind}:${hit.origin}:${hit.name}`;
    const seen = byKey.get(key);
    if (!seen) {
      byKey.set(key, hit);
      continue;
    }
    const richer = (h: Hit) => (h.installs ?? 0) + h.description.length;
    if (richer(hit) > richer(seen)) byKey.set(key, hit);
  }
  return [...byKey.values()];
}

export function collectCatalog(home: string, installed: Set<string>): Hit[] {
  const text = readIfFile(
    join(home, ".claude", "plugins", "plugin-catalog-cache.json"),
  );
  if (!text) return [];
  let catalog: Record<string, any>;
  try {
    catalog =
      (
        JSON.parse(text) as {
          catalog?: { plugins?: Record<string, any> };
        }
      ).catalog?.plugins ?? {};
  } catch {
    return [];
  }
  const hits: Hit[] = [];
  for (const [id, entry] of Object.entries(catalog)) {
    if (installed.has(id)) continue;
    const tokens = entry?.tokens ?? {};
    const firstModel = Object.values(tokens)[0] as
      { always_on?: number } | undefined;
    hits.push({
      name: entry?.plugin ?? id.split("@")[0],
      kind: "plugin",
      tier: "marketplace",
      origin: id,
      status: "catalog",
      description: entry?.marketplace_entry?.description ?? "",
      tags: (entry?.components?.skills ?? [])
        .map((s: { name?: string }) => s.name ?? "")
        .filter(Boolean),
      installs: entry?.unique_installs,
      alwaysOnTokens: firstModel?.always_on,
      score: 0,
    });
  }
  return hits;
}

// ── remote tier ────────────────────────────────────────────────────────────

export function parseSkillsShResponse(payload: unknown): Hit[] {
  const skills = (payload as { skills?: unknown[] })?.skills;
  if (!Array.isArray(skills)) return [];
  return skills.flatMap((raw) => {
    const entry = raw as {
      name?: string;
      source?: string;
      installs?: number;
      id?: string;
    };
    if (!entry.name) return [];
    const source = entry.source ?? "";
    return [
      {
        name: entry.name,
        kind: "skill" as Kind,
        tier: "remote" as Tier,
        origin: source,
        status: "skills.sh",
        description: "",
        tags: [],
        installs: entry.installs,
        url: `https://skills.sh/${entry.id ?? `${source}/${entry.name}`}`,
        score: 0,
      },
    ];
  });
}

async function searchSkillsSh(
  query: string,
  limit: number,
): Promise<{ hits: Hit[]; note?: string }> {
  const base = process.env.SKILLS_API_URL ?? "https://skills.sh";
  const url = `${base}/api/search?q=${encodeURIComponent(query)}&limit=${limit}`;
  try {
    const response = await fetch(url, {
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok)
      return { hits: [], note: `skills.sh HTTP ${response.status}` };
    return { hits: parseSkillsShResponse(await response.json()) };
  } catch (error) {
    return {
      hits: [],
      note: `skills.sh unreachable (${(error as Error).message})`,
    };
  }
}

function searchGitHubCode(
  query: string,
  limit: number,
): { hits: Hit[]; note?: string } {
  const keywords = tokenize(query).slice(0, 3).join(" ");
  if (!keywords)
    return { hits: [], note: "no searchable keywords for gh code search" };

  let out: string;
  try {
    out = execFileSync(
      "gh",
      [
        "search",
        "code",
        keywords,
        "--filename",
        "SKILL.md",
        "--limit",
        String(limit),
        "--json",
        "repository,path",
      ],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 20000,
      },
    );
  } catch {
    return {
      hits: [],
      note: "gh code search unavailable (not installed, unauthenticated, or rate-limited)",
    };
  }
  try {
    const rows = JSON.parse(out) as {
      repository?: { nameWithOwner?: string };
      path?: string;
    }[];
    return {
      hits: rows.map((row) => {
        const repo = row.repository?.nameWithOwner ?? "";
        const path = row.path ?? "";
        return {
          name: basename(path.replace(/\/SKILL\.md$/, "")),
          kind: "skill" as Kind,
          tier: "remote" as Tier,
          origin: repo,
          status: "github",
          description: path,
          tags: [],
          url: `https://github.com/${repo}/blob/HEAD/${path}`,
          score: 0,
        };
      }),
    };
  } catch {
    return { hits: [], note: "gh code search returned unparsable JSON" };
  }
}

// ── output ─────────────────────────────────────────────────────────────────

function truncate(text: string, max: number): string {
  const clean = text.replace(/\s+/g, " ").replace(/\|/g, "/").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

function renderTable(hits: Hit[]): string[] {
  const lines = [
    "| score | name | kind | tier | origin | status | description |",
    "| --- | --- | --- | --- | --- | --- | --- |",
  ];
  for (const hit of hits) {
    const extra = [
      hit.installs !== undefined ? `${hit.installs} installs` : "",
      hit.alwaysOnTokens !== undefined
        ? `${hit.alwaysOnTokens} tok always-on`
        : "",
    ]
      .filter(Boolean)
      .join(", ");
    const description = [truncate(hit.description, 90), extra]
      .filter(Boolean)
      .join(" · ");
    lines.push(
      `| ${hit.score} | ${hit.name} | ${hit.kind} | ${hit.tier} | ${truncate(hit.origin, 40)} | ${hit.status || "-"} | ${description || "-"} |`,
    );
  }
  return lines;
}

function usage(): void {
  console.log(
    [
      "usage: find-skill.sh <query...> [options]",
      "       find-skill.sh --exact <name> [--remote]",
      "",
      "  --root <dir>    project to search (default: the working directory)",
      "  --tier <list>   comma list of project,user,installed,marketplace,remote",
      "  --remote        include the remote tier (skills.sh + gh code search)",
      "  --no-remote     force the remote tier off",
      "  --exact <name>  exact-name collision check across every selected tier",
      "  --limit <n>     max rows per tier (default 8)",
      "  --json          machine-readable output",
    ].join("\n"),
  );
}

interface Options {
  query: string;
  root: string;
  tiers: Tier[];
  remote: boolean;
  exact?: string;
  limit: number;
  json: boolean;
}

// ── exact-name collision check ───────────────────────────────────────

/**
 * A declared name is written the way it is invoked — `/man`, `/pr:create` — while
 * the name being checked is bare. Comparing the two raw makes an owned name read as free, so both
 * sides lose the leading slash and any `<category>:` prefix before they meet.
 */
export function normaliseExactName(raw: string): string {
  const bare = raw.trim().replace(/^\/+/, "");
  const afterPrefix = bare.slice(bare.lastIndexOf(":") + 1);
  return afterPrefix.toLowerCase();
}

/** Every spelling a hit answers to: as declared, normalised, and as the file on disk. */
export function exactNameCandidates(
  hit: Pick<Hit, "name" | "basename">,
): string[] {
  const raw = [hit.name, normaliseExactName(hit.name), hit.basename ?? ""];
  return [...new Set(raw.filter(Boolean).map((n) => n.toLowerCase()))];
}

export function matchesExactName(
  hit: Pick<Hit, "name" | "basename">,
  needle: string,
): boolean {
  const candidates = exactNameCandidates(hit);
  return (
    candidates.includes(needle.trim().toLowerCase()) ||
    candidates.includes(normaliseExactName(needle))
  );
}

export function parseArgs(argv: string[]): Options | null {
  const options: Options = {
    query: "",
    root: process.cwd(),
    tiers: [...LOCAL_TIERS],
    remote: false,
    limit: 8,
    json: false,
  };
  const words: string[] = [];
  let explicitTiers = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--remote") options.remote = true;
    else if (arg === "--no-remote") options.remote = false;
    else if (arg === "--json") options.json = true;
    else if (arg === "--limit") options.limit = Number(argv[++i] ?? 8);
    else if (arg === "--exact") options.exact = argv[++i];
    else if (arg === "--root") options.root = argv[++i] ?? options.root;
    else if (arg === "--tier") {
      const raw = (argv[++i] ?? "").split(",").map((t) => t.trim());
      options.tiers = raw.filter((t): t is Tier =>
        (ALL_TIERS as string[]).includes(t),
      );
      explicitTiers = true;
    } else if (arg.startsWith("--")) return null;
    else words.push(arg);
  }
  options.query = words.join(" ");
  if (options.remote && !explicitTiers)
    options.tiers = [...LOCAL_TIERS, "remote"];
  if (!options.remote)
    options.tiers = options.tiers.filter((t) => t !== "remote");
  if (!options.query && !options.exact) return null;
  if (!Number.isFinite(options.limit) || options.limit < 1) options.limit = 8;
  return options;
}

async function main(): Promise<number> {
  const options = parseArgs(process.argv.slice(2));
  if (!options) {
    usage();
    return process.argv.length > 2 ? 2 : 0;
  }

  const root = options.root;
  const home = homedir();
  const notes: string[] = [];
  let hits: Hit[] = [];

  if (options.tiers.includes("project")) {
    const resolved = resolveLayout(root);
    if (resolved.layout) {
      hits.push(...collectProject(resolved.layout));
      notes.push(`project layout: ${resolved.layout.layout}`);
      if (!readStagedPaths(resolved.layout).applicable)
        notes.push(
          "staged-plugins tier not applicable — this layout keeps no staged-plugin registry",
        );
    } else if (resolved.note) {
      notes.push(resolved.note);
    }
  }
  if (options.tiers.includes("user")) hits.push(...collectUser(home));

  const { hits: installedHits, installed } = collectInstalled(root, home);
  if (options.tiers.includes("installed")) hits.push(...installedHits);
  else notes.push("installed tier skipped (--tier)");
  if (options.tiers.includes("marketplace"))
    hits.push(...collectMarketplace(home, installed));
  else notes.push("marketplace tier skipped (--tier)");

  // The remote tier runs BEFORE the exact check: a name the ecosystem already owns is exactly
  // what an exact check exists to find, so it must never return ahead of the search.
  if (options.remote) {
    const remoteQuery = options.query || options.exact || "";
    const skillsSh = await searchSkillsSh(remoteQuery, options.limit);
    const github = searchGitHubCode(remoteQuery, options.limit);
    hits.push(...skillsSh.hits, ...github.hits);
    for (const note of [skillsSh.note, github.note]) if (note) notes.push(note);
  } else {
    notes.push("remote tier OFF — add --remote to search skills.sh + GitHub");
  }

  if (options.exact) {
    const clashes = hits.filter((h) => matchesExactName(h, options.exact!));
    if (options.json) {
      console.log(
        JSON.stringify({ exact: options.exact, clashes, notes }, null, 2),
      );
    } else if (clashes.length === 0) {
      console.log(
        `NAME FREE: "${options.exact}" matches nothing across ${options.tiers.join(", ")}.`,
      );
    } else {
      console.log(
        `NAME TAKEN: "${options.exact}" — ${clashes.length} match(es).`,
      );
      console.log("");
      console.log(renderTable(clashes).join("\n"));
    }
    // A tier that never ran cannot report a clash, so "free" is only as wide as
    // the tiers behind it. The notes say which ones those were.
    if (!options.json && notes.length) {
      console.log("");
      for (const note of notes) console.log(`note: ${note}`);
    }
    return 0;
  }

  hits = rank(hits, options.query);

  const perTier = new Map<Tier, Hit[]>();
  for (const hit of hits) {
    const bucket = perTier.get(hit.tier) ?? [];
    if (bucket.length < options.limit) bucket.push(hit);
    perTier.set(hit.tier, bucket);
  }
  const shown = ALL_TIERS.flatMap((tier) => perTier.get(tier) ?? []);

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          query: options.query,
          tiers: options.tiers,
          hits: shown,
          notes,
        },
        null,
        2,
      ),
    );
    return 0;
  }

  console.log(
    `find-skill: "${options.query}" — ${hits.length} match(es) across ${options.tiers.join(", ")}`,
  );
  console.log("");
  if (shown.length === 0)
    console.log("No local or remote match. Authoring a new tool is justified.");
  else console.log(renderTable(shown).join("\n"));
  for (const tier of ALL_TIERS) {
    const total = hits.filter((h) => h.tier === tier).length;
    const capped = total - (perTier.get(tier)?.length ?? 0);
    if (capped > 0)
      notes.push(
        `${tier}: ${capped} further match(es) not shown (--limit ${options.limit})`,
      );
  }
  if (notes.length) {
    console.log("");
    for (const note of notes) console.log(`note: ${note}`);
  }
  return 0;
}

if (import.meta.main) {
  process.exit(await main());
}
