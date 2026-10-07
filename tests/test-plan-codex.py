#!/usr/bin/env python3
"""Codex package and unchanged Plan verifier contract, using a standalone copy."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "plugins" / "plan"


class PlanCodexPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plan-codex-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plugin = self.root / "plan"
        shutil.copytree(SOURCE, self.plugin)
        self.project = self.root / "project"
        self.project.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.project, check=True)
        (self.project / "README.md").write_text("fixture\n")
        subprocess.run(["git", "add", "README.md"], cwd=self.project, check=True)
        subprocess.run(
            ["git", "-c", "user.name=Plan Test", "-c", "user.email=plan@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
            cwd=self.project, check=True,
        )
        self.tree = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=self.project, text=True
        ).strip()

    def verify(self):
        environment = os.environ.copy()
        for name in ("PLAN_ARTIFACTS_DIR", "PLAN_CLAUDE_ARGS", "PLAN_CLAUDE_COMMAND"):
            environment.pop(name, None)
        # The verifier must not require the Claude CLI, even in a Codex-only host.
        environment["PLAN_CLAUDE_COMMAND"] = "/no/claude/installed"
        return subprocess.run(
            ["bash", str(self.plugin / "scripts" / "plan-research.sh"),
             "--slug", "fixture", "--verify", "1"],
            cwd=self.project, env=environment, text=True, capture_output=True,
        )

    def test_standalone_copy_has_both_manifests_and_native_prompt_references(self):
        codex = json.loads((self.plugin / ".codex-plugin" / "plugin.json").read_text())
        claude = json.loads((self.plugin / ".claude-plugin" / "plugin.json").read_text())
        self.assertEqual((codex["name"], codex["version"]), ("plan", "0.3.0"))
        self.assertEqual(claude["version"], codex["version"])
        self.assertEqual(codex["skills"], "./skills/")
        skill_path = self.plugin / "skills" / "research" / "SKILL.md"
        skill = skill_path.read_text()
        for relative in (
            "../../commands/research.md",
            "../../agents/answer-researcher.md",
            "../../agents/answer-proover.md",
        ):
            self.assertIn(relative, skill)
            self.assertTrue((skill_path.parent / relative).is_file())
        for native_tool in ("spawn_agent", "followup_task", "wait_agent"):
            self.assertIn(native_tool, skill)
        self.assertIn("not** executable tool calls or runtime permission controls", skill)
        command = (self.plugin / "commands" / "research.md").read_text()
        researcher = (self.plugin / "agents" / "answer-researcher.md").read_text()
        proover = (self.plugin / "agents" / "answer-proover.md").read_text()
        self.assertIn('subagent_type="plan:answer-researcher"', command)
        self.assertIn('subagent_type="plan:answer-proover"', command)
        self.assertIn("RESEARCH_DONE", researcher)
        self.assertIn("PROOF_DONE", proover)
        self.assertIn("<n>-proof.json", proover)
        self.assertIn("--verify", (self.plugin / "README.md").read_text())

    def test_same_named_claude_skill_executes_command_body_without_recursion(self):
        skill_path = self.plugin / "skills" / "research" / "SKILL.md"
        skill = skill_path.read_text()
        self.assertEqual(skill_path.parent.name, "research")
        self.assertIn("\nname: research\n", skill)
        host_section = skill.index("## Select the host")
        claude_branch = skill.index("**Claude Code:**", host_section)
        codex_branch = skill.index("**Codex:**", claude_branch)
        native_mapping = skill.index("## Codex native phase mapping", codex_branch)
        self.assertLess(claude_branch, codex_branch)
        claude_body = skill[claude_branch:codex_branch]
        self.assertIn("execute the unchanged [command body](../../commands/research.md)", claude_body)
        self.assertIn('subagent_type="plan:answer-researcher"', claude_body)
        self.assertIn('subagent_type="plan:answer-proover"', claude_body)
        self.assertIn("Do **not** invoke `/plan:research` from this skill", claude_body)
        self.assertIn("`allowed-tools` frontmatter is not automatically inherited", claude_body)
        self.assertNotIn("call native `spawn_agent`", claude_body)
        self.assertIn("call native `spawn_agent`", skill[native_mapping:])

    def test_copied_verifier_replays_contract_and_records_hashes(self):
        proof_dir = self.project / "tmp" / "a" / "fixture"
        proof_dir.mkdir(parents=True)
        missing = self.verify()
        self.assertEqual(missing.returncode, 3, missing.stdout + missing.stderr)

        artifact = proof_dir / "1-proof.sh"
        artifact.write_text('#!/usr/bin/env bash\nprintf "PROOF boundary: %s\\n" "$(cat tmp/a/fixture/value)"\n')
        (proof_dir / "value").write_text("true")
        contract = proof_dir / "1-proof.json"
        contract.write_text(json.dumps({
            "hypothesis": 1,
            "artifact": "tmp/a/fixture/1-proof.sh",
            "run": "bash tmp/a/fixture/1-proof.sh",
            "cases": [{"case": "boundary", "expect": "true", "got": "true"}],
            "revisions": [],
        }))
        contract_hash = hashlib.sha256(contract.read_bytes()).hexdigest()

        match = self.verify()
        self.assertEqual(match.returncode, 0, match.stdout + match.stderr)
        self.assertIn("1 cases match", match.stdout)
        self.assertIn(f"tree {self.tree}; contract {contract_hash}", match.stdout)
        self.assertEqual((proof_dir / "1-proof.verify.out").read_text(), "PROOF boundary: true\n")
        rows = (proof_dir / "1-proof.runs.tsv").read_text().splitlines()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].split("\t")[1:], [self.tree, contract_hash, "0"])

        (proof_dir / "value").write_text("false")
        regression = self.verify()
        self.assertEqual(regression.returncode, 1, regression.stdout + regression.stderr)
        self.assertIn("regression: boundary: expect true, got false", regression.stdout)
        rows = (proof_dir / "1-proof.runs.tsv").read_text().splitlines()
        self.assertEqual(rows[-1].split("\t")[1:], [self.tree, contract_hash, "1"])

        artifact.write_text("#!/usr/bin/env bash\nexit 9\n")
        execution_failure = self.verify()
        self.assertEqual(execution_failure.returncode, 2,
                         execution_failure.stdout + execution_failure.stderr)
        self.assertIn("execution failure", execution_failure.stderr)
        # The current verifier exits before record_run on non-zero execution.
        self.assertEqual(len((proof_dir / "1-proof.runs.tsv").read_text().splitlines()), 2)

        data = json.loads(contract.read_text())
        data["revisions"] = [{
            "case": "boundary", "old_expect": "false", "new_expect": "true",
            "requirement": "boundary stays true",
        }]
        contract.write_text(json.dumps(data))
        invalid = self.verify()
        self.assertEqual(invalid.returncode, 3, invalid.stdout + invalid.stderr)
        self.assertIn("revision missing", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
