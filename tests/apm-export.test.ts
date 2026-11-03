import { describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, renameSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { differences, generate, synchronize } from "../scripts/apm-export";

const rootToken = "${CLAUDE_PLUGIN_ROOT}";
const document = (body: string, extra = "") => `---\nname: demo\ndescription: Fixture skill\n${extra}---\n\n${body}\n`;
function fixture(): string { return mkdtempSync(join(tmpdir(), "apm-export-test-")); }
function put(root: string, path: string, content: string | Buffer, mode = 0o644): void {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), content);
  chmodSync(join(root, path), mode);
}
function body(files: ReturnType<typeof generate>, path = "demo/.apm/skills/demo/SKILL.md"): string {
  return files.get(path)!.bytes.toString();
}
function report(files: ReturnType<typeof generate>) { return JSON.parse(body(files, "report.json")); }

describe("portable APM export", () => {
  test("bundles script siblings, preserving executable modes and binary bytes", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document(`Run bash \"${rootToken}/scripts/run.sh\".`));
    put(root, "plugins/demo/scripts/run.sh", '#!/bin/sh\nexec node "${0%/*}/run.js" "$@"\n', 0o755);
    put(root, "plugins/demo/scripts/run.js", 'console.log("fixture");\n');
    put(root, "plugins/demo/resources/config.json", '{"bundled":true}\n');
    put(root, "plugins/demo/skills/demo/data/model.bin", Buffer.from([0, 255, 10, 20]));
    const files = generate(root);
    expect(body(files)).toContain('${SKILL_DIR}/_plugin/scripts/run.sh');
    expect(body(files)).toContain("Keep the working directory at the target project");
    expect(files.get("demo/.apm/skills/demo/_plugin/scripts/run.sh")).toEqual({ bytes: readFileSync(join(root, "plugins/demo/scripts/run.sh")), mode: 0o755 });
    expect(files.has("demo/.apm/skills/demo/_plugin/scripts/run.js")).toBe(true);
    expect(files.has("demo/.apm/skills/demo/_plugin/resources/config.json")).toBe(true);
    expect(files.get("demo/.apm/skills/demo/data/model.bin")!.bytes).toEqual(Buffer.from([0, 255, 10, 20]));
    synchronize(root, files, false);
    expect(lstatSync(join(root, "export/demo/.apm/skills/demo/_plugin/scripts/run.sh")).mode & 0o777).toBe(0o755);
  });

  test("own skill scripts and their templates retain their relative layout", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document(`Run ${rootToken}/skills/demo/scripts/run.sh`));
    put(root, "plugins/demo/skills/demo/scripts/run.sh", '#!/bin/sh\ncat "${0%/*}/../templates/config.txt"\n', 0o755);
    put(root, "plugins/demo/skills/demo/templates/config.txt", "template\n");
    put(root, "plugins/demo/skills/demo/references/run.md", "Read [script](../scripts/run.sh).\n");
    const files = generate(root);
    expect(body(files)).toContain('${SKILL_DIR}/scripts/run.sh');
    expect(files.has("demo/.apm/skills/demo/templates/config.txt")).toBe(true);
    expect(body(files, "demo/.apm/skills/demo/references/run.md")).toBe("Read [script](../scripts/run.sh).\n");
  });

  test("command bodies are embedded, invocation locks kept, native-name collisions disambiguated", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document("Native body."));
    put(root, "plugins/demo/commands/demo.md", document("Exact command body $ARGUMENTS.", "disable-model-invocation: true\n"));
    const files = generate(root);
    const command = body(files, "demo/.apm/skills/demo-command/SKILL.md");
    expect(command).toContain("Codex entry point for /demo:demo");
    expect(command).toContain("Exact command body $ARGUMENTS.");
    expect(command).toContain("disable-model-invocation: true");
    expect(command).not.toContain(".rulesync");
    expect(body(files)).toContain("Native body.");
  });

  test.each([
    ["missing plugin resource", `Run ${rootToken}/scripts/absent.sh`, "missing or unsafe plugin resource"],
    ["external relative dependency", "Read [prompt](../../agents/prompt.md)", "relative dependency escapes"],
    ["unresolved root", `Resolve ${rootToken} at runtime`, "unresolved plugin-root"],
    ["source pointer", "Read .rulesync/commands/run.md", "source-layout dependency"],
    ["installed registry", "Read ~/.claude/plugins/installed_plugins.json", "installed-plugin registry"],
  ])("skips %s with a deterministic reason", (_label, input, reason) => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document(input));
    const files = generate(root);
    expect(report(files).packages[0].skipped[0].reason).toContain(reason);
    expect(files.has("demo/.apm/skills/demo/SKILL.md")).toBe(false);
    expect([...files.keys()].some(path => path.startsWith("demo/"))).toBe(false);
    expect(differences(generate(root), files)).toEqual([]);
  });

  test("reports every plugin but emits no empty package directories", () => {
    const root = fixture();
    put(root, "plugins/valid/skills/demo/SKILL.md", document("Portable body"));
    put(root, "plugins/skipped/skills/demo/SKILL.md", document("Read ~/.claude/plugins/installed_plugins.json"));
    put(root, "plugins/hooks/hooks/hooks.json", "{}\n");
    put(root, "export/skipped/apm.yml", "stale package\n");
    mkdirSync(join(root, "export/hooks"), { recursive: true });
    const files = generate(root);
    expect(report(files).packages.map((entry: { name: string }) => entry.name)).toEqual(["hooks", "skipped", "valid"]);
    expect(report(files).packages.find((entry: { name: string }) => entry.name === "skipped").skipped[0].reason).toContain("installed-plugin registry");
    expect([...files.keys()].some(path => /^(hooks|skipped)\//.test(path))).toBe(false);
    expect(synchronize(root, files, true)).toContain("stale hooks/");
    synchronize(root, files, false, path => renameSync(path, join(root, `trashed-${path.split("/").pop()}`)));
    expect(existsSync(join(root, "export/hooks"))).toBe(false);
    expect(existsSync(join(root, "export/skipped"))).toBe(false);
    expect(existsSync(join(root, "export/valid/apm.yml"))).toBe(true);
    expect(synchronize(root, files, true)).toEqual([]);
  });

  test("portable base-directory instruction appears once", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document(`The script lives at \`${rootToken}/scripts/run.sh\`. A harness without that variable resolves\nthe plugin root as the directory two levels above this file.`));
    put(root, "plugins/demo/scripts/run.sh", "#!/bin/sh\n", 0o755);
    const exported = body(generate(root));
    expect(exported.match(/directory containing this SKILL\.md/g)).toHaveLength(1);
    expect(exported).not.toContain("two levels above");
    expect(exported).toContain('The script lives at `${SKILL_DIR}/_plugin/scripts/run.sh`.');
  });

  test("checks bundled scripts for unavailable runtime dependencies without rewriting them", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document(`Run ${rootToken}/scripts/run.sh`));
    put(root, "plugins/demo/scripts/run.sh", `#!/bin/sh\ncat ${rootToken}/settings.json\n`, 0o755);
    expect(report(generate(root)).packages[0].skipped[0].reason).toContain("runtime plugin-root dependency");
  });

  test("symlinks cannot escape the source skill tree", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document("Body"));
    put(root, "secret", "outside");
    symlinkSync(join(root, "secret"), join(root, "plugins/demo/skills/demo/link"));
    expect(report(generate(root)).packages[0].skipped[0].reason).toContain("symlink");
  });

  test("generation is idempotent, check detects drift and never writes", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/demo/SKILL.md", document("Body"));
    const expected = generate(root);
    expect(synchronize(root, expected, false).length).toBeGreaterThan(0);
    expect(synchronize(root, expected, false)).toEqual([]);
    expect(synchronize(root, expected, true)).toEqual([]);
    put(root, "export/demo/apm.yml", "drift\n");
    put(root, "export/stale.txt", "keep until generation\n");
    const changes = synchronize(root, expected, true, () => { throw new Error("check must not trash"); });
    expect(changes).toContain("changed demo/apm.yml");
    expect(changes).toContain("stale stale.txt");
    expect(readFileSync(join(root, "export/demo/apm.yml"), "utf8")).toBe("drift\n");
    expect(readFileSync(join(root, "export/stale.txt"), "utf8")).toBe("keep until generation\n");
    const moved: string[] = [];
    synchronize(root, expected, false, path => { moved.push(path); renameSync(path, join(root, "trashed.txt")); });
    expect(moved).toEqual([join(root, "export/stale.txt")]);
    expect(existsSync(join(root, "trashed.txt"))).toBe(true);
    expect(synchronize(root, expected, true)).toEqual([]);
  });

  test("plugin prefixes cannot cause collisions across packages", () => {
    const root = fixture();
    put(root, "plugins/alpha/skills/beta-thing/SKILL.md", document("First"));
    put(root, "plugins/alpha-beta/skills/thing/SKILL.md", document("Second"));
    const files = generate(root);
    expect(body(files, "alpha/.apm/skills/alpha-beta-thing/SKILL.md")).toContain("First");
    expect(body(files, "alpha-beta/.apm/skills/alpha-beta-thing-skill/SKILL.md")).toContain("Second");
  });

  test("a skipped named dependency also skips its caller", () => {
    const root = fixture();
    put(root, "plugins/demo/skills/broken/SKILL.md", document("Read ~/.claude/plugins/installed_plugins.json"));
    put(root, "plugins/demo/skills/caller/SKILL.md", document("Load demo:broken before continuing."));
    put(root, "plugins/demo/skills/broken-other/SKILL.md", document("Independent skill."));
    put(root, "plugins/demo/commands/valid.md", document("Load demo:broken-other."));
    const files = generate(root);
    expect(report(files).packages[0].skipped.find((entry: { source: string }) => entry.source.includes("caller"))!.reason).toContain("referenced skill demo:broken was skipped");
    expect(body(files, "demo/.apm/skills/demo-valid/SKILL.md")).toContain("Load demo-broken-other.");
  });

  test("license notices travel with the package and the installed skill", () => {
    const root = fixture();
    put(root, "LICENSE", "Fixture license\n");
    put(root, "plugins/demo/skills/demo/SKILL.md", document("Body"));
    const files = generate(root);
    expect(body(files, "demo/LICENSE")).toBe("Fixture license\n");
    expect(body(files, "demo/.apm/skills/demo/LICENSE.apm-export")).toBe("Fixture license\n");
  });

  test("check on a missing export directory creates nothing", () => {
    const root = fixture();
    put(root, "plugins/demo/commands/run.md", document("Do the work"));
    expect(synchronize(root, generate(root), true).length).toBeGreaterThan(0);
    expect(existsSync(join(root, "export"))).toBe(false);
  });
});
