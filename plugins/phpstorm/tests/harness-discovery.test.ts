// plugins/phpstorm/tests/harness-discovery.test.ts
//
// Harness self-test, not a test of the plugin. Proves the root runner and CI
// discover a *.test.ts suite living under plugins/<name>/tests/ and run it
// under `bun test`. A ported TypeScript test no runner picks up is not
// coverage, so this file exists to keep that path honest.
//
// Set HARNESS_SELF_FAIL=1 to make the last case fail on purpose.

import { describe, expect, test } from "bun:test";

describe("harness discovery", () => {
  test("bun test reaches a suite under plugins/<name>/tests/", () => {
    expect(import.meta.file).toBe("harness-discovery.test.ts");
  });

  test("the suite sits under a plugin's tests directory", () => {
    expect(import.meta.dir).toMatch(/\/plugins\/[^/]+\/tests$/);
  });

  test("a deliberate failure fails the run when asked", () => {
    expect(process.env.HARNESS_SELF_FAIL === "1").toBe(false);
  });
});
