import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join, normalize, resolve } from "node:path";

type Asset = Readonly<{ bytes: Buffer; mode: number }>;
type Files = Map<string, Asset>;
type Candidate = Readonly<{ plugin: string; source: string; name: string; kind: "skill" | "command" }>;
type Included = Readonly<{ source: string; name: string; assets: string[] }>;
type Skipped = Readonly<{ source: string; reason: string }>;
const rootToken = "${CLAUDE_PLUGIN_ROOT}";
const skillToken = "${SKILL_DIR}";
const textExtensions = /\.(md|txt|json|ya?ml|sh|py|[cm]?js|ts|toml)$/;

function names(path: string): string[] {
  return existsSync(path) ? readdirSync(path).sort() : [];
}

function readTree(path: string, prefix = ""): Files {
  const files: Files = new Map();
  if (existsSync(path) && lstatSync(path).isSymbolicLink()) throw new Error("symlink cannot be an export or resource directory");
  for (const name of names(path)) {
    const full = join(path, name);
    const key = join(prefix, name);
    const stat = lstatSync(full);
    if (stat.isSymbolicLink()) throw new Error(`symlink requires an explicit portable replacement: ${key}`);
    if (stat.isDirectory()) for (const entry of readTree(full, key)) files.set(...entry);
    else if (stat.isFile()) files.set(key, { bytes: readFileSync(full), mode: stat.mode & 0o777 });
    else throw new Error(`unsupported file type: ${key}`);
  }
  return files;
}

function textAsset(text: string): Asset {
  return { bytes: Buffer.from(text), mode: 0o644 };
}

function parseDocument(text: string): { metadata: Record<string, unknown>; body: string } {
  const match = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(text);
  if (!match) throw new Error("missing YAML frontmatter");
  const metadata = Bun.YAML.parse(match[1]);
  if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) throw new Error("invalid YAML frontmatter");
  return { metadata: metadata as Record<string, unknown>, body: text.slice(match[0].length) };
}

function exportName(plugin: string, name: string): string {
  return plugin === name ? name : `${plugin}-${name}`;
}

function candidates(root: string, plugin: string): Candidate[] {
  const base = join(root, "plugins", plugin);
  const skills = names(join(base, "skills")).filter(name => existsSync(join(base, "skills", name, "SKILL.md")));
  const used = new Set(skills.map(name => exportName(plugin, name)));
  const result: Candidate[] = skills.map(name => ({ plugin, source: `skills/${name}/SKILL.md`, name: exportName(plugin, name), kind: "skill" }));
  for (const command of names(join(base, "commands")).filter(name => name.endsWith(".md"))) {
    let name = exportName(plugin, basename(command, ".md"));
    while (used.has(name)) name += "-command";
    used.add(name);
    result.push({ plugin, source: `commands/${command}`, name, kind: "command" });
  }
  return result;
}

function assertPortableText(text: string, path: string): void {
  const rules: [RegExp, string][] = [
    [/installed_plugins\.json|(?:~|\$HOME|\$\{HOME\})\/\.claude\/plugins\/|["']\.claude["'],\s*["']plugins["']/, "installed-plugin registry or cache dependency"],
    [/\.rulesync\//, "source-layout dependency requires a dedicated portable adapter"],
    [/\/Users\/[A-Za-z0-9_-]+\//, "machine-specific home path"],
    [/Reading this file is not loading it/, "requires the original host's Skill invocation tracking"],
  ];
  for (const [pattern, reason] of rules) if (pattern.test(text)) throw new Error(`${path}: ${reason}`);
}

function bundleRootReferences(base: string, text: string, ownDirectory: string | undefined, files: Files): void {
  const references = [...text.matchAll(/\$\{CLAUDE_PLUGIN_ROOT\}\/([A-Za-z0-9_./-]+)/g)].map(match => match[1]);
  for (const path of references) {
    if (path.includes("..") || !existsSync(join(base, path))) throw new Error(`missing or unsafe plugin resource: ${path}`);
    if (ownDirectory && path.startsWith(`${ownDirectory}/`)) continue;
    const subtree = path.startsWith("skills/") ? path.split("/").slice(0, 2).join("/") : path.split("/")[0];
    const source = join(base, subtree);
    if (!lstatSync(source).isDirectory()) files.set(`_plugin/${subtree}`, { bytes: readFileSync(source), mode: lstatSync(source).mode & 0o777 });
    else for (const [name, asset] of readTree(source)) files.set(`_plugin/${subtree}/${name}`, asset);
    if (subtree === "scripts") bundleRuntimeResources(base, files);
  }
}

function bundleRuntimeResources(base: string, files: Files): void {
  for (const directory of ["resources", "templates", "lib", "data", "assets", "vendor"]) {
    for (const [name, asset] of readTree(join(base, directory))) files.set(`_plugin/${directory}/${name}`, asset);
  }
}

function rewriteMarkdown(text: string, ownDirectory: string | undefined, outputPath = "SKILL.md"): string {
  let result = ownDirectory ? text.replaceAll(`${rootToken}/${ownDirectory}/`, `${skillToken}/`) : text;
  result = result.replaceAll(`${rootToken}/`, `${skillToken}/_plugin/`);
  if (result.includes(rootToken)) throw new Error("unresolved plugin-root discovery instruction");
  assertRelativeReferences(result, outputPath);
  return result.replace(" A harness without that variable resolves\nthe plugin root as the directory two levels above this file.", "");
}

function assertRelativeReferences(text: string, outputPath: string): void {
  const links = [...text.matchAll(/\]\((\.\.\/[^)]+)\)/g)].map(match => match[1]);
  const paths = [...text.matchAll(/`(\.\.\/[^`]*\.(?:md|sh|py|ts|js))`/g)].map(match => match[1]);
  for (const reference of [...links, ...paths]) {
    const destination = normalize(join(dirname(outputPath), reference));
    if (destination.startsWith("../")) throw new Error("relative dependency escapes the skill directory");
  }
}

function assertNoRegisteredAgents(base: string, text: string): void {
  for (const file of names(join(base, "agents"))) {
    const name = basename(file, ".md");
    if (text.includes(name)) throw new Error(`registered agent ${name} needs a native-host adapter`);
  }
}

function portableFiles(root: string, candidate: Candidate, all: Candidate[]): Files {
  const base = join(root, "plugins", candidate.plugin);
  const ownDirectory = candidate.kind === "skill" ? dirname(candidate.source) : undefined;
  const files = ownDirectory ? readTree(join(base, ownDirectory)) : new Map<string, Asset>();
  const document = parseDocument(readFileSync(join(base, candidate.source), "utf8"));
  assertNoRegisteredAgents(base, document.body);
  bundleRootReferences(base, document.body, ownDirectory, files);
  for (const [path, asset] of files) {
    if (!textExtensions.test(path) && !(asset.mode & 0o111)) continue;
    const text = asset.bytes.toString("utf8");
    assertPortableText(text, path);
    if (path.endsWith(".md")) {
      bundleRootReferences(base, text, ownDirectory, files);
      files.set(path, { ...asset, bytes: Buffer.from(rewriteMarkdown(text, ownDirectory, path)) });
    } else if (text.includes("CLAUDE_PLUGIN_ROOT")) throw new Error(`${path}: runtime plugin-root dependency; script bytes must remain unchanged`);
  }
  assertPortableText(document.body, candidate.source);
  let body = rewriteMarkdown(document.body, ownDirectory);
  for (const other of all) body = body.replaceAll(aliasPattern(other), other.name);
  const metadata = { ...document.metadata, name: candidate.name };
  if (typeof metadata.description !== "string") throw new Error("description must be a string");
  const adapter = candidate.kind === "command" ? `Codex entry point for /${candidate.plugin}:${basename(candidate.source, ".md")}. Treat $ARGUMENTS as the user's arguments. Use the host's available tools; source tool/model metadata does not grant permissions.\n\n` : "";
  const paths = body.includes(skillToken) ? "Set SKILL_DIR to the absolute directory containing this SKILL.md before running bundled commands. Keep the working directory at the target project; bundled paths are resolved from SKILL_DIR.\n\n" : "";
  files.set("SKILL.md", textAsset(`---\n${yamlLines(metadata)}\n---\n\n${adapter}${paths}${body.trimStart()}`));
  return files;
}

export function generate(root: string): Files {
  const output: Files = new Map();
  const plugins = names(join(root, "plugins")).filter(name => lstatSync(join(root, "plugins", name)).isDirectory());
  const all = uniqueNames(plugins.flatMap(plugin => candidates(root, plugin)));
  const prepared = prepareCandidates(root, all);
  const packages = plugins.map(plugin => buildPackage(root, plugin, all, prepared, output));
  output.set("report.json", textAsset(`${JSON.stringify({ format: 1, packages }, null, 2)}\n`));
  return output;
}

function uniqueNames(candidates: Candidate[]): Candidate[] {
  const used = new Set<string>();
  return candidates.map(candidate => {
    let name = candidate.name;
    while (used.has(name)) name += `-${candidate.kind}`;
    used.add(name);
    return { ...candidate, name };
  });
}

type Prepared = Readonly<{ files?: Files; reason?: string }>;

function sourceAlias(candidate: Candidate): string {
  const local = candidate.kind === "skill" ? basename(dirname(candidate.source)) : basename(candidate.source, ".md");
  return `${candidate.plugin}:${local}`;
}

function aliasPattern(candidate: Candidate): RegExp {
  return new RegExp(`${sourceAlias(candidate)}(?![a-zA-Z0-9_-])`, "g");
}

function prepareCandidates(root: string, all: Candidate[]): Map<Candidate, Prepared> {
  const prepared = new Map<Candidate, Prepared>();
  for (const candidate of all) {
    try { prepared.set(candidate, { files: portableFiles(root, candidate, all) }); }
    catch (error) { prepared.set(candidate, { reason: error instanceof Error ? error.message : String(error) }); }
  }
  let changed = true;
  while (changed) {
    changed = false;
    for (const candidate of all) {
      if (!prepared.get(candidate)?.files) continue;
      const { body } = parseDocument(readFileSync(join(root, "plugins", candidate.plugin, candidate.source), "utf8"));
      const missing = all.find(other => other !== candidate && aliasPattern(other).test(body) && !prepared.get(other)?.files);
      if (!missing) continue;
      prepared.set(candidate, { reason: `referenced skill ${sourceAlias(missing)} was skipped: ${prepared.get(missing)!.reason}` });
      changed = true;
    }
  }
  return prepared;
}

function yamlLines(value: Record<string, unknown>): string {
  return Object.entries(value).map(([key, item]) => `${key}: ${JSON.stringify(item)}`).join("\n");
}

function buildPackage(root: string, plugin: string, all: Candidate[], prepared: Map<Candidate, Prepared>, output: Files) {
  const path = join(root, "plugins", plugin, ".claude-plugin", "plugin.json");
  const metadata = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {};
  const included: Included[] = [];
  const skipped: Skipped[] = [];
  for (const candidate of all.filter(item => item.plugin === plugin)) {
    const { files, reason } = prepared.get(candidate)!;
    if (!files) {
      skipped.push({ source: candidate.source, reason: reason! });
      continue;
    }
    for (const [name, asset] of files) output.set(`${plugin}/.apm/skills/${candidate.name}/${name}`, asset);
    const assets = [...files.keys()];
    if (existsSync(join(root, "LICENSE"))) assets.push("LICENSE.apm-export");
    included.push({ source: candidate.source, name: candidate.name, assets: assets.sort() });
  }
  if (!included.length) return { name: plugin, version: metadata.version ?? "0.1.0", included, skipped, note: "No portable skills; no package emitted. Hooks and registered agents are not exported." };
  const manifest = { name: plugin, version: metadata.version ?? "0.1.0", description: `Portable skills exported from the ${plugin} plugin.`, license: "MIT" };
  output.set(`${plugin}/apm.yml`, textAsset(`${yamlLines(manifest)}\n`));
  if (existsSync(join(root, "LICENSE"))) {
    const license = { bytes: readFileSync(join(root, "LICENSE")), mode: 0o644 };
    output.set(`${plugin}/LICENSE`, license);
    for (const skill of included) output.set(`${plugin}/.apm/skills/${skill.name}/LICENSE.apm-export`, license);
  }
  return { name: plugin, version: manifest.version, included, skipped };
}

export function differences(expected: Files, actual: Files): string[] {
  const keys = [...new Set([...expected.keys(), ...actual.keys()])].sort();
  return keys.flatMap(path => {
    const want = expected.get(path), have = actual.get(path);
    if (!want) return [`stale ${path}`];
    if (!have) return [`missing ${path}`];
    return !want.bytes.equals(have.bytes) || want.mode !== have.mode ? [`changed ${path}`] : [];
  });
}

function moveToTrash(path: string): void {
  if (!Bun.which("trash")) throw new Error("stale export files require the trash CLI; install it and rerun generation");
  const result = Bun.spawnSync(["trash", path], { stdout: "pipe", stderr: "pipe" });
  if (result.exitCode) throw new Error(`trash failed: ${result.stderr.toString().trim()}`);
}

function obsoletePackages(directory: string, expected: Files): string[] {
  const retained = new Set([...expected.keys()].map(path => path.split("/")[0]));
  return names(directory).filter(name => !retained.has(name) && lstatSync(join(directory, name)).isDirectory());
}

export function synchronize(root: string, expected: Files, check: boolean, trash = moveToTrash): string[] {
  const directory = join(root, "export");
  const actual = readTree(directory);
  const obsolete = obsoletePackages(directory, expected);
  const changes = [...differences(expected, actual), ...obsolete.map(name => `stale ${name}/`)];
  if (check || !changes.length) return changes;
  for (const name of obsolete) trash(join(directory, name));
  for (const path of actual.keys()) {
    if (!expected.has(path) && !obsolete.includes(path.split("/")[0])) trash(join(directory, path));
  }
  for (const [path, asset] of expected) {
    const existing = actual.get(path);
    if (existing?.bytes.equals(asset.bytes) && existing.mode === asset.mode) continue;
    const destination = join(directory, path);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, asset.bytes);
    chmodSync(destination, asset.mode);
  }
  return changes;
}

function main(): number {
  const args = process.argv.slice(2);
  if (args.some(arg => arg !== "--check")) {
    console.error("Usage: scripts/apm-export.sh [--check]");
    return 2;
  }
  const root = resolve(import.meta.dir, "..");
  const check = args.includes("--check");
  const changes = synchronize(root, generate(root), check);
  if (check && changes.length) {
    console.error(`Export drift:\n${changes.join("\n")}\nRun scripts/apm-export.sh and commit export/.`);
    return 1;
  }
  console.log(check ? "APM export is current." : `APM export generated (${changes.length} changed files).`);
  return 0;
}

if (import.meta.main) {
  try { process.exitCode = main(); }
  catch (error) { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; }
}
