#!/usr/bin/env python3
"""Checks for the commentable proposal page that /peer-chat:design opens in agterm."""

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "plugins/peer-chat/scripts/peer-chat-review-page.py"
PROPOSAL = "# Plan (v2)\n\n1. **One app.** Uses `node:sqlite`.\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n"
SUBMITTED = {"document": "proposal-v2 review", "general": "ship it", "comments": [{"idx": 2, "comment": "why?"}]}


class ReviewPageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.topic = Path(self.tmp.name) / "topic"
        self.topic.mkdir()
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        (self.topic / "07-left-round.msg").write_text("x")
        self.proposal = self.topic / "proposal-v2.md"
        self.proposal.write_text(PROPOSAL)

    def tearDown(self):
        self.tmp.cleanup()

    def run_page(self, *extra, proposal=None, env_extra=None):
        env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": self.tmp.name, **(env_extra or {})}
        args = ["python3", str(SCRIPT), "--proposal", str(proposal or self.proposal),
                "--topic-dir", str(self.topic), "--pane", "left", *extra]
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def fake_agtermctl(self, stdout, code):
        tool = self.bin / "agtermctl"
        tool.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" > {self.tmp.name}/argv\ncat <<'EOF'\n{stdout}\nEOF\nexit {code}\n")
        tool.chmod(tool.stat().st_mode | stat.S_IEXEC)

    def test_page_embeds_the_proposal_raw_and_takes_the_next_number(self):
        result = self.run_page("--no-open")
        self.assertEqual(result.returncode, 0, result.stderr)
        page = Path(json.loads(result.stdout)["page"])
        self.assertEqual(page.name, "08-left-review-v2.html")
        html = page.read_text()
        self.assertIn(PROPOSAL, html)
        self.assertIn("<title>proposal-v2 review</title>", html)
        self.assertNotIn("__MARKDOWN__", html)
        self.assertEqual(stat.S_IMODE(page.stat().st_mode), 0o600)

    def test_script_end_tag_in_the_proposal_is_refused(self):
        self.proposal.write_text("bad </SCRIPT> tag\n")
        result = self.run_page("--no-open")
        self.assertEqual(result.returncode, 2)
        self.assertIn("</script", result.stderr)
        self.assertFalse(any(p.suffix == ".html" for p in self.topic.iterdir()))

    def test_a_file_not_named_proposal_vN_is_refused(self):
        other = self.topic / "notes.md"
        other.write_text("x")
        result = self.run_page("--no-open", proposal=other)
        self.assertEqual(result.returncode, 2)
        self.assertIn("proposal-vN.md", result.stderr)

    def test_submitted_comments_land_beside_the_page(self):
        self.fake_agtermctl(json.dumps({"outcome": "submitted", "value": json.dumps(SUBMITTED)}), 0)
        result = self.run_page(env_extra={"AGTERM_SESSION_ID": "S1", "AGTERM_SOCKET": "/tmp/agterm.sock"})
        self.assertEqual(result.returncode, 0, result.stderr)
        reply = json.loads(result.stdout)
        self.assertEqual(Path(reply["comments"]).name, "09-user-comments-v2.json")
        self.assertEqual(reply["count"], 2)
        self.assertEqual(json.loads(Path(reply["comments"]).read_text()), SUBMITTED)
        argv = (Path(self.tmp.name) / "argv").read_text()
        for flag in ("--html", "--js", "--block", "--target S1", "--socket /tmp/agterm.sock"):
            self.assertIn(flag, argv)

    def test_a_dismissed_page_exits_3_and_saves_nothing(self):
        self.fake_agtermctl("", 2)
        result = self.run_page(env_extra={"AGTERM_SESSION_ID": "S1"})
        self.assertEqual(result.returncode, 3)
        self.assertIn("dismissed", result.stderr)
        self.assertFalse(any(p.suffix == ".json" for p in self.topic.iterdir()))

    def test_outside_agterm_it_names_the_page_to_share(self):
        result = self.run_page()
        self.assertEqual(result.returncode, 2)
        self.assertIn("not inside agterm", result.stderr)


if __name__ == "__main__":
    unittest.main()
