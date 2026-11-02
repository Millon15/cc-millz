import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "plugins/voice-call/scripts/workspace_rules.py"
spec = importlib.util.spec_from_file_location("workspace_rules", SCRIPT)
wr = importlib.util.module_from_spec(spec)
sys.modules["workspace_rules"] = wr
spec.loader.exec_module(wr)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


class Fixture:
    """A fake home and repo: user rules, project rules (nested, frontmatter, symlinks), and an auto-memory dir."""

    def __init__(self, folder):
        self.base = Path(folder).resolve()
        self.home = self.base / "home"
        self.repo = self.base / "repo"
        (self.repo / ".git").mkdir(parents=True)
        self.cwd = self.repo / "app"
        self.cwd.mkdir()
        write(self.home / ".claude/CLAUDE.md", "# Global\n\nAnswer in English.\n")
        write(self.home / ".claude/rules/style.md", "# Style\n\nUse jq for JSON.\n")
        write(
            self.repo / "CLAUDE.md",
            "# Repo guide\n\n## Gotchas\n\nRun make db first.\n",
        )
        write(
            self.repo / ".claude/rules/deploy.md",
            "# Deploy Flow\n\nmigrations land on master only.\n",
        )
        write(
            self.repo / ".claude/rules/nested/sql.md",
            "---\npaths:\n  - 'migrations/**'\n  - 'sql/**'\n---\n# SQL Rules\n\nNever DROP a.b tables.\n",
        )
        write(self.base / "outside/secret.md", "# Secret\n\nmigrations token 123\n")
        (self.repo / ".claude/rules/escape.md").symlink_to(
            self.base / "outside/secret.md"
        )
        write(self.repo / ".claude/rules/huge.md", "# Huge\n\n" + "migrations " * 40000)
        self.memory = (
            self.home / ".claude/projects" / wr.project_slug(self.repo) / "memory"
        )
        write(
            self.memory / "MEMORY.md",
            "# Memory Index\n\n- [Deploy note](deploy-note.md)\n",
        )
        write(
            self.memory / "deploy-note.md",
            "---\nname: deploy-note\ndescription: migrations need a DevOps ask\n---\n\nAsk in the SQL channel.\n",
        )

    def rules(self, cwd=None):
        return wr.WorkspaceRules(str(cwd or self.cwd), home=self.home)


class WorkspaceRulesTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.fx = Fixture(self.folder.name)

    def tearDown(self):
        self.folder.cleanup()

    def paths(self, catalog):
        return {entry["path"]: entry for entry in catalog["files"]}

    def test_catalog_finds_every_scope_from_a_nested_cwd(self):
        files = self.paths(self.fx.rules().catalog())
        self.assertEqual(files["~/.claude/CLAUDE.md"]["scope"], "user")
        self.assertEqual(files["~/.claude/rules/style.md"]["scope"], "user-rules")
        self.assertEqual(files["CLAUDE.md"]["scope"], "project")
        self.assertEqual(files[".claude/rules/nested/sql.md"]["scope"], "project-rules")
        self.assertEqual(files["memory/deploy-note.md"]["scope"], "memory")
        self.assertEqual(files["memory/MEMORY.md"]["scope"], "memory")

    def test_catalog_keeps_frontmatter_scope_and_headings(self):
        files = self.paths(self.fx.rules().catalog())
        self.assertEqual(
            files[".claude/rules/nested/sql.md"]["applies"], "migrations/**, sql/**"
        )
        self.assertEqual(
            files[".claude/rules/nested/sql.md"]["headings"], ["SQL Rules"]
        )
        self.assertIsNone(files[".claude/rules/deploy.md"]["applies"])
        self.assertEqual(files["CLAUDE.md"]["headings"], ["Repo guide", "Gotchas"])
        self.assertEqual(
            files["memory/deploy-note.md"]["description"],
            "migrations need a DevOps ask",
        )

    def test_symlink_escape_and_oversize_files_are_left_out(self):
        files = self.paths(self.fx.rules().catalog())
        self.assertNotIn(".claude/rules/escape.md", files)
        self.assertNotIn(".claude/rules/huge.md", files)
        matches = self.fx.rules().search("token 123")["matches"]
        self.assertEqual(matches, [])

    def test_symlink_inside_the_repo_is_followed(self):
        write(
            self.fx.repo / ".rulesync/rules/real.md", "# Real Rule\n\nkeep tirith on\n"
        )
        (self.fx.repo / ".claude/rules/linked.md").symlink_to(
            self.fx.repo / ".rulesync/rules/real.md"
        )
        self.assertIn(".claude/rules/linked.md", self.paths(self.fx.rules().catalog()))

    def test_search_is_literal_case_insensitive_with_line_and_heading(self):
        result = self.fx.rules().search("A.B")
        self.assertEqual(len(result["matches"]), 1)
        match = result["matches"][0]
        self.assertEqual(
            (match["path"], match["line"], match["heading"]),
            (".claude/rules/nested/sql.md", 8, "SQL Rules"),
        )
        self.assertIn("Never DROP a.b tables.", match["text"])
        self.assertEqual(self.fx.rules().search("a?b")["matches"], [])

    def test_search_covers_rules_and_memory_notes(self):
        paths = {
            match["path"] for match in self.fx.rules().search("migrations")["matches"]
        }
        self.assertEqual(
            paths,
            {
                ".claude/rules/deploy.md",
                ".claude/rules/nested/sql.md",
                "memory/deploy-note.md",
            },
        )

    def test_search_limit_and_text_cap_set_truncated(self):
        for index in range(30):
            write(
                self.fx.repo / f".claude/rules/many/r{index:02}.md",
                f"# Rule {index}\n\nshared needle {'x' * 900}\n",
            )
        result = self.fx.rules().search("shared needle", limit=5)
        self.assertEqual(len(result["matches"]), 5)
        self.assertTrue(result["truncated"])
        wide = self.fx.rules().search("shared needle", limit=20)
        self.assertLessEqual(sum(len(match["text"]) for match in wide["matches"]), 8000)
        self.assertTrue(wide["truncated"])

    def test_search_rejects_empty_or_oversized_queries_and_bad_limits(self):
        for query, limit in (
            ("", 5),
            ("   ", 5),
            ("x" * 201, 5),
            ("ok", 0),
            ("ok", 21),
        ):
            with (
                self.subTest(query=query[:10], limit=limit),
                self.assertRaises(ValueError),
            ):
                self.fx.rules().search(query, limit)

    def test_primer_is_at_most_400_bytes_and_names_the_repo_and_tool(self):
        primer = self.fx.rules().primer()
        self.assertLessEqual(len(primer.encode()), 400)
        self.assertIn("repo", primer)
        self.assertIn("read_workspace_rules", primer)

    def test_auto_memory_directory_setting_wins(self):
        custom = self.fx.base / "custom-memory"
        write(custom / "note.md", "# Custom\n\ncustom memory\n")
        write(
            self.fx.home / ".claude/settings.json",
            json.dumps({"autoMemoryDirectory": str(custom)}),
        )
        files = self.paths(self.fx.rules().catalog())
        self.assertIn("memory/note.md", files)
        self.assertNotIn("memory/deploy-note.md", files)

    def test_cwd_outside_any_repo_reads_user_files_only(self):
        loose = self.fx.base / "loose"
        loose.mkdir()
        scopes = {entry["scope"] for entry in self.fx.rules(loose).catalog()["files"]}
        self.assertEqual(scopes, {"user", "user-rules"})

    def test_missing_cwd_does_not_raise(self):
        catalog = self.fx.rules(self.fx.base / "gone").catalog()
        self.assertEqual(
            {entry["scope"] for entry in catalog["files"]}, {"user", "user-rules"}
        )

    def test_catalog_is_bounded(self):
        for index in range(400):
            write(
                self.fx.memory / f"n{index:03}.md",
                f"---\ndescription: note {index} {'y' * 80}\n---\n\nbody\n",
            )
        catalog = self.fx.rules().catalog()
        self.assertTrue(catalog["truncated"])
        self.assertLessEqual(len(json.dumps(catalog)), 16000)


    def test_memory_is_keyed_by_the_repo_not_the_subdirectory(self):
        deep = self.fx.repo / "app/src"
        deep.mkdir(parents=True)
        self.assertIn("memory/deploy-note.md", self.paths(self.fx.rules(deep).catalog()))

    def test_linked_worktree_shares_the_main_checkout_memory(self):
        gitdir = self.fx.repo / ".git/worktrees/wt"
        gitdir.mkdir(parents=True)
        write(gitdir / "commondir", "../..\n")
        tree = self.fx.base / "wt"
        write(tree / ".git", f"gitdir: {gitdir}\n")
        write(tree / "CLAUDE.md", "# Worktree copy\n")
        files = self.paths(self.fx.rules(tree).catalog())
        self.assertIn("memory/deploy-note.md", files)
        self.assertEqual(files["CLAUDE.md"]["headings"], ["Worktree copy"])

    def test_file_cap_stops_reading_and_flags_both_catalog_and_search(self):
        original = wr.MAX_FILES
        wr.MAX_FILES = 3
        try:
            rules = self.fx.rules()
            self.assertEqual(len(rules.files), 3)
            self.assertTrue(rules.catalog()["truncated"])
            result = rules.search("migrations")
            self.assertEqual(result["matches"], [])
            self.assertTrue(result["truncated"])
        finally:
            wr.MAX_FILES = original

    def test_long_neighbour_never_pushes_the_hit_out_of_the_excerpt(self):
        write(self.fx.repo / ".claude/rules/wide.md", "# Wide\n\n" + "z" * 5000 + "\nthe needle line\n")
        match = self.fx.rules().search("needle line")
        self.assertIn("the needle line", match["matches"][0]["text"])
        self.assertEqual(match["matches"][0]["line"], 4)
        self.assertTrue(match["truncated"])

    def test_overlong_hit_line_is_centred_on_the_needle(self):
        write(self.fx.repo / ".claude/rules/long.md", "# Long\n\n" + "a" * 3000 + " deepneedle " + "b" * 3000 + "\n")
        result = self.fx.rules().search("deepneedle")
        self.assertIn("deepneedle", result["matches"][0]["text"])
        self.assertLessEqual(len(result["matches"][0]["text"]), 1200)
        self.assertTrue(result["truncated"])

    def test_short_excerpt_reports_no_truncation(self):
        self.assertFalse(self.fx.rules().search("Use jq")["truncated"])


if __name__ == "__main__":
    unittest.main()
