#!/usr/bin/env python3
"""Regression checks for shared ask dispositions."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "shared/peer-chat"))
from peer_chat_core import Disposition, now_utc, parse_dispositions, plan_body


class DispositionTests(unittest.TestCase):
    def test_reasons_keep_nested_and_trailing_parentheses(self):
        cases = [
            ("answered: plain reason", "answered", "plain reason"),
            (
                "answered: fixed in f758b465 (the shim) and c77f4207",
                "answered",
                "fixed in f758b465 (the shim) and c77f4207",
            ),
            ("declined(needs the user's call (scope))", "declined", "needs the user's call (scope)"),
            ("deferred(wait for CI (run 42) to finish)", "deferred", "wait for CI (run 42) to finish"),
            ("answered: see (a)", "answered", "see (a)"),
            ("answered: ends with a smiley :)", "answered", "ends with a smiley :)"),
            ("withdrawn: obsolete after retry (attempt 2)", "withdrawn", "obsolete after retry (attempt 2)"),
            ("declined(scope (a)) and (b))", "declined", "scope (a)) and (b)"),
            ("deferred(  until (CI) finishes  )  ", "deferred", "until (CI) finishes"),
        ]
        for body, kind, reason in cases:
            with self.subTest(body=body):
                self.assertEqual(parse_dispositions(["#left-001 " + body]), [Disposition("left-001", kind, reason)])

    def test_empty_reasons_still_parse(self):
        for kind in ["answered", "withdrawn", "deferred", "declined"]:
            for suffix in ["", ":", "()"]:
                with self.subTest(kind=kind, suffix=suffix):
                    self.assertEqual(
                        parse_dispositions(["#left-001 " + kind + suffix]),
                        [Disposition("left-001", kind, "")],
                    )

    def test_legacy_ids_and_optional_reason_delimiters_keep_working(self):
        cases = [
            ("#claude-001 answered plain", Disposition("claude-001", "answered", "plain")),
            ("#codex-1234 declined: scope", Disposition("codex-1234", "declined", "scope")),
            ("#right-001 deferred(wait for CI", Disposition("right-001", "deferred", "wait for CI")),
        ]
        for line, expected in cases:
            with self.subTest(line=line):
                self.assertEqual(parse_dispositions([line]), [expected])

    def test_unknown_kinds_and_short_ids_are_not_dispositions(self):
        self.assertEqual(parse_dispositions(["#left-01 answered: short", "#left-001 abandoned(reason)"]), [])

    def test_message_planning_keeps_the_unwrapped_reason(self):
        reason = "wait for the complete result (including the final CI job) before deciding"
        plan = plan_body(["#left-001 deferred(" + reason + ")"], "right", None, now_utc(), width=30)
        self.assertGreater(len(plan.text.splitlines()), 1)
        self.assertEqual(plan.dispositions, [Disposition("left-001", "deferred", reason)])


if __name__ == "__main__":
    unittest.main()
