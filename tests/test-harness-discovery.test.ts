// tests/test-harness-discovery.test.ts
//
// Harness self-test. Proves the root runner and CI discover a *.test.ts suite
// at the repo root and run it under `bun test`. A ported TypeScript test no
// runner picks up is not coverage, so this file keeps that path honest.
//
// Set HARNESS_SELF_FAIL=1 to make the last case fail on purpose.

import { describe, expect, test } from "bun:test";

describe("harness discovery", () => {
  test("bun test reaches a suite in the root tests directory", () => {
    expect(import.meta.file).toBe("test-harness-discovery.test.ts");
  });

  test("the suite sits at the repo root, not inside a plugin", () => {
    expect(import.meta.dir).toMatch(/\/tests$/);
    expect(import.meta.dir).not.toMatch(/\/plugins\//);
  });

  test("a deliberate failure fails the run when asked", () => {
    expect(process.env.HARNESS_SELF_FAIL === "1").toBe(false);
  });
});
