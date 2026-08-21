/**
 * skill-dirs.ts — where SKILL.md files live under a skills directory.
 *
 * A deliberate plugin-local copy of a small pure function. The finder used to
 * import this from the plugin resolver of the project it was born in; a plugin
 * published on its own cannot depend on a private module, and duplicating six
 * lines is cheaper than either a shared package or a runtime probe for one.
 */

import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

/** Immediate subdirectory names, or none when the directory is absent or unreadable. */
export function listDirs(dir: string): string[] {
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name);
  } catch {
    return [];
  }
}

/** Dirs containing SKILL.md, searched up to 2 levels deep (plugins may group skills by category). */
export function discoverSkillDirs(skillsDir: string, depth = 0): string[] {
  if (depth > 2) return [];
  return listDirs(skillsDir).flatMap((name) => {
    const dir = join(skillsDir, name);
    if (existsSync(join(dir, "SKILL.md"))) return [dir];
    return discoverSkillDirs(dir, depth + 1);
  });
}
