"""Protocol tests use real subprocesses and filesystem locks, not fake host delivery."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "plugins/peer-chat-bg/scripts/peer-chat-bg.py"


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        (self.repo / ".peer-chat-bg.json").write_text('{}')
        (self.repo / ".gitignore").write_text('/tmp/peer-chat-bg/\n')
        (self.repo / "app.txt").write_text('version one\n')
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], check=True)
        self.proof = self.repo / "tmp/peer-chat-bg/actual-result.txt"
        self.proof.parent.mkdir(parents=True)
        self.proof.write_text('test fixture: simulated native result; not live host integration\n')
        self.run_id = None
        self.call("init", "--host", "codex", "--parent-id", "parent-real-id", "--check", "suite")
        self.run_id = self.call("status")["run_id"]
        self.call("bind", "--agent-id", "child-real-id")
        self.target = self.call("target", "--output", "tmp/peer-chat-bg/target.json")["target"]

    def call(self, *args, body=None, status=0, helper=HELPER, run=None):
        command = [sys.executable, str(helper), "--repo", str(self.repo), "--slug", "topic"]
        selected_run = self.run_id if run is None else run
        if selected_run:
            command += ["--run", selected_run]
        result = subprocess.run(command + list(args), input=body, text=True, capture_output=True)
        self.assertEqual(result.returncode, status, (result.args, result.stdout, result.stderr))
        return json.loads(result.stdout if result.returncode == 0 else result.stderr)

    def prepare(self, text, sender="left", key="ask"):
        return self.call("prepare", "--sender", sender, "--key", key, "--stdin", body=text)

    def receipt(self, message, state, actor=None, status=0):
        if actor is None:
            role = message["recipient"] if state in ("acknowledged", "answered") else message["sender"]
            actor = "parent-real-id" if role == "left" else "child-real-id"
        return self.call("receipt", "--message-id", message["message_id"], "--state", state,
                         "--actor-id", actor, "--evidence", str(self.proof), status=status)

    def deliver(self, message):
        self.receipt(message, "dispatching")
        self.receipt(message, "submitted")
        self.receipt(message, "acknowledged")

    def exchange(self):
        ask = self.prepare("🔎 artifact\n❓ Does the check pass?")
        self.deliver(ask)
        answer = self.prepare("🎯 #left-001 answered: yes\n🔎 actual-result.txt", "right", "answer")
        self.deliver(answer)
        return ask, answer

    def finalize(self, actor, target=None, status=0):
        return self.call("finalize", "--target", target or self.target, "--actor-id", actor,
                         "--evidence", str(self.proof), status=status)

    def check(self, target=None, state="passed", status=0):
        return self.call("check", "--name", "suite", "--state", state, "--target", target or self.target,
                         "--evidence", str(self.proof), status=status)

    def test_round_trip_requires_answer_check_and_both_confirmations(self):
        ask = self.prepare("🔎 proof\n❓ Is it true?")
        self.deliver(ask)
        self.assertIn("open", self.finalize("parent-real-id", status=2)["error"])
        answer = self.prepare("#left-001 answered: yes", "right", "answer")
        self.deliver(answer)
        self.assertIn("checks", self.finalize("parent-real-id", status=2)["error"])
        self.check()
        first = self.finalize("parent-real-id")
        self.assertEqual(first["phase"], "active")
        last = self.finalize("child-real-id")
        self.assertEqual(last["phase"], "finalized")
        self.assertEqual(self.call("status")["open_asks"], [])

    def test_prepare_idempotency_preserves_ask_ids_and_rejects_changed_body(self):
        first = self.prepare("❓ First?")
        replay = self.prepare("❓ First?")
        self.assertEqual(first["message_id"], replay["message_id"])
        self.assertTrue(replay["replayed"])
        self.assertEqual(self.call("status")["counters"]["left"], 1)
        result = self.call("prepare", "--sender", "left", "--key", "ask", "--stdin", body="❓ Different?", status=2)
        self.assertIn("different", result["error"])

    def test_concurrent_reservations_have_distinct_ids(self):
        def reserve(number):
            return self.prepare("❓ Question " + str(number), key="k" + str(number))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            messages = list(pool.map(reserve, range(16)))
        ids = [message["new_asks"][0][0] for message in messages]
        self.assertEqual(len(set(ids)), 16)
        self.assertEqual(set(ids), {f"left-{index:03d}" for index in range(1, 17)})

    def test_concurrent_identical_key_is_one_reservation(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            messages = list(pool.map(lambda _: self.prepare("❓ One?"), range(6)))
        self.assertEqual(len({item["message_id"] for item in messages}), 1)
        self.assertEqual(self.call("status")["counters"]["left"], 1)

    def test_uncertain_send_is_not_automatically_retriable_or_finalizable(self):
        message = self.prepare("❓ Did you receive this?")
        self.receipt(message, "dispatching")
        self.receipt(message, "uncertain")
        self.assertFalse(self.receipt(message, "dispatching")["dispatch_permitted"])
        replay = self.prepare("❓ Did you receive this?")
        self.assertEqual(replay["state"], "uncertain")
        self.assertIn("open", self.finalize("parent-real-id", status=2)["error"])
        self.receipt(message, "acknowledged")
        self.assertEqual(self.call("status")["messages"][message["message_id"]]["state"], "acknowledged")

    def test_dispatching_crash_is_durable_and_asks_are_conservative(self):
        message = self.prepare("❓ Maybe delivered?")
        self.receipt(message, "dispatching")
        state = self.call("status")
        self.assertEqual(state["unresolved_messages"], [message["message_id"]])
        self.assertEqual(state["open_asks"], ["left-001"])

    def test_answered_receipt_does_not_close_ask_without_disposition(self):
        message = self.prepare("❓ Answer?")
        self.receipt(message, "dispatching")
        self.receipt(message, "answered")
        self.assertEqual(self.call("status")["open_asks"], ["left-001"])

    def test_wrong_identity_and_stale_run_are_rejected(self):
        result = self.call("bind", "--agent-id", "different-child", status=2)
        self.assertIn("already bound", result["error"])
        result = self.call("prepare", "--sender", "left", "--key", "x", "--stdin", body="text", run="old-run", status=2)
        self.assertIn("stale", result["error"])
        message = self.prepare("hello")
        self.receipt(message, "dispatching")
        self.assertIn("actor", self.receipt(message, "acknowledged", actor="other-child", status=2)["error"])
        self.assertIn("right", self.receipt(message, "acknowledged", actor="parent-real-id", status=2)["error"])

    def test_missing_unknown_own_and_repeated_dispositions_are_rejected(self):
        question = self.prepare("❓ A question?")
        self.deliver(question)
        result = self.call("prepare", "--sender", "right", "--key", "bad", "--stdin", body="No disposition", status=2)
        self.assertIn("no disposition", result["error"])
        for sender, text, expected in [
            ("right", "#left-001 answered\n#right-999 answered", "unknown ask"),
            ("left", "#left-001 answered", "your own"),
            ("right", "#left-001 answered\n#left-001 answered", "duplicate"),
            ("right", "#left-001 deferred()", "reason"),
        ]:
            result = self.call("prepare", "--sender", sender, "--key", "bad", "--stdin", body=text, status=2)
            self.assertIn(expected, result["error"])
        response = self.prepare("#left-001 answered: yes", "right", "good")
        self.deliver(response)
        result = self.call("prepare", "--sender", "right", "--key", "again", "--stdin", body="#left-001 answered", status=2)
        self.assertIn("already closed", result["error"])

    def test_deferred_ask_still_blocks_finalization(self):
        question = self.prepare("❓ A question?")
        self.deliver(question)
        response = self.prepare("#left-001 deferred(after checking)", "right", "defer")
        self.deliver(response)
        self.check()
        self.assertIn("deferred", self.finalize("parent-real-id", status=2)["error"])
        self.assertEqual(self.call("status")["open_asks"], ["left-001"])

    def test_prepared_message_revalidates_asks_at_dispatch_time(self):
        planned = self.prepare("Independent finding", sender="right", key="early")
        question = self.prepare("❓ New question after preparing?")
        self.deliver(question)
        result = self.receipt(planned, "dispatching", status=2)
        self.assertIn("no disposition", result["error"])
        self.assertEqual(self.call("status")["messages"][planned["message_id"]]["state"], "prepared")

    def test_fast_ack_accepts_late_submission_receipt_without_downgrading(self):
        for observed in ("acknowledged", "answered"):
            message = self.prepare("A message without asks", key=observed)
            self.receipt(message, "dispatching")
            self.receipt(message, observed)
            late = self.receipt(message, "submitted")
            self.assertEqual(late["state"], observed)
            self.assertFalse(late["dispatch_permitted"])
            self.assertEqual(late["receipts"][-1]["state"], "submitted")
            replay = self.receipt(message, "submitted")
            self.assertEqual(replay["state"], observed)
            self.assertTrue(replay["replayed"])
            self.assertFalse(replay["dispatch_permitted"])

    def test_receipt_replay_is_idempotent_but_changed_evidence_refused(self):
        message = self.prepare("hello")
        self.receipt(message, "dispatching")
        self.receipt(message, "submitted")
        self.assertTrue(self.receipt(message, "submitted")["replayed"])
        self.proof.write_text("changed evidence")
        self.assertIn("differs", self.receipt(message, "submitted", status=2)["error"])
        self.assertEqual(len(self.call("status")["messages"][message["message_id"]]["receipts"]), 2)

    def test_proved_failure_and_cancellation_do_not_leave_phantom_asks(self):
        first = self.prepare("❓ Never sent?")
        self.receipt(first, "cancelled")
        second = self.prepare("❓ Transport refused before delivery?", key="second")
        self.receipt(second, "dispatching")
        self.receipt(second, "failed")
        self.assertEqual(self.call("status")["open_asks"], [])
        self.assertEqual(self.call("status")["unresolved_messages"], [])

    def test_submitted_cannot_later_be_called_proved_not_delivered(self):
        message = self.prepare("❓ Sent?")
        self.receipt(message, "dispatching")
        self.receipt(message, "submitted")
        self.receipt(message, "uncertain")
        self.assertIn("contradicts", self.receipt(message, "failed", status=2)["error"])
        self.assertEqual(self.call("status")["open_asks"], ["left-001"])

    def test_check_targets_and_peer_target_mismatch_block_close(self):
        self.exchange()
        self.check()
        self.finalize("parent-real-id")
        other = self.call("target", "--output", "tmp/peer-chat-bg/other-target.json")["target"]
        self.assertIn("different target", self.finalize("child-real-id", target=other, status=2)["error"])
        self.check(state="failed")
        self.assertEqual(self.call("status")["confirmations"], {})

    def test_modified_new_deleted_files_and_manifest_tampering_block_finalization(self):
        self.exchange()
        self.check()
        self.finalize("parent-real-id")
        app = self.repo / "app.txt"
        for change, restore in [
            (lambda: app.write_text("version two"), lambda: app.write_text("version one\n")),
            (lambda: app.unlink(), lambda: app.write_text("version one\n")),
            (lambda: (self.repo / "new.txt").write_text("new untracked"), lambda: (self.repo / "new.txt").unlink()),
        ]:
            change()
            self.assertIn("working tree changed", self.finalize("child-real-id", status=2)["error"])
            self.assertIn("working tree changed", self.check(status=2)["error"])
            restore()
        manifest = self.repo / "tmp/peer-chat-bg/target.json"
        manifest.write_text(manifest.read_text() + " ")
        self.assertIn("manifest changed", self.finalize("child-real-id", status=2)["error"])

    def test_clean_git_target_rejects_dirty_or_untracked_files(self):
        self.exchange()
        sha = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        target = "git:" + sha
        self.check(target=target)
        (self.repo / "untracked.txt").write_text("new")
        self.assertIn("clean", self.finalize("parent-real-id", target=target, status=2)["error"])

    def test_git_target_does_not_trust_assume_unchanged_index_flags(self):
        self.exchange()
        sha = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        target = "git:" + sha
        self.check(target=target)
        subprocess.run(["git", "-C", str(self.repo), "update-index", "--assume-unchanged", "app.txt"], check=True)
        (self.repo / "app.txt").write_text("hidden modification")
        self.assertIn("bytes changed", self.finalize("parent-real-id", target=target, status=2)["error"])

    def test_mutated_check_evidence_blocks_finalization(self):
        self.exchange()
        self.check()
        self.proof.write_text("different check output")
        self.assertIn("evidence changed", self.finalize("parent-real-id", status=2)["error"])

    def test_ack_only_cannot_close_without_a_peer_origin_reply(self):
        self.deliver(self.prepare("An opening with no question"))
        self.check()
        self.assertIn("two-way", self.finalize("parent-real-id", status=2)["error"])

    def test_unignored_state_root_is_refused_without_creating_state(self):
        (self.repo / ".gitignore").write_text("")
        result = subprocess.run([sys.executable, str(HELPER), "--repo", str(self.repo), "--slug", "unignored", "init",
                                 "--host", "codex", "--parent-id", "another-parent"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Git-ignored", json.loads(result.stderr)["error"])
        self.assertFalse((self.repo / "tmp/peer-chat-bg/unignored").exists())

    def test_no_agterm_or_checkout_siblings_required_in_packaged_copy(self):
        copied = self.repo / "isolated-plugin"
        shutil.copytree(ROOT / "plugins/peer-chat-bg/scripts", copied)
        result = self.call("status", helper=copied / "peer-chat-bg.py")
        self.assertEqual(result["run_id"], self.run_id)
        result = self.call("prepare", "--sender", "left", "--key", "copied", "--stdin", body="❓ Packaged?", helper=copied / "peer-chat-bg.py")
        self.assertEqual(result["new_asks"][0][0], "left-001")

    def test_explain_has_no_side_effects_and_rejects_bad_profile(self):
        separate = tempfile.TemporaryDirectory()
        self.addCleanup(separate.cleanup)
        work = Path(separate.name)
        profile = work / ".peer-chat-bg.json"
        profile.write_text('{"state_dir":"scratch/peers"}')
        def explain():
            return subprocess.run(["bash", str(HELPER.with_suffix(".sh")), "--repo", str(work), "--explain"], text=True, capture_output=True)
        result = explain()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["values"], {"state_dir": "scratch/peers"})
        self.assertEqual(data["sources"], {"state_dir": "profile"})
        self.assertEqual(list(work.iterdir()), [profile])
        for invalid in ("{", "[]", '{"state_dir":"../escape"}', '{"state_dir":"/tmp"}', '{"unknown":1}'):
            profile.write_text(invalid)
            self.assertEqual(explain().returncode, 2)
        profile.unlink()
        self.assertEqual(explain().returncode, 2)
        self.assertEqual(list(work.iterdir()), [])

    def test_explicit_ask_id_is_rejected(self):
        result = self.call("prepare", "--sender", "left", "--key", "forge", "--stdin", body="❓ #left-004 fabricated", status=2)
        self.assertIn("own IDs", result["error"])

    def test_run_identity_cannot_be_reinitialized_by_different_parent(self):
        result = self.call("init", "--host", "codex", "--parent-id", "somebody-else", "--check", "suite", status=2)
        self.assertIn("different identity", result["error"])


class SharedPackagingTests(unittest.TestCase):
    def test_generated_copies_are_current(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/sync-peer-chat-shared.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installer_copies_core_and_installed_paste_imports_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {**os.environ, "CODEX_HOME": str(root / "codex"), "PEER_CHAT_BIN_DIR": str(root / "bin")}
            result = subprocess.run(["bash", str(ROOT / "plugins/peer-chat/scripts/peer-chat-install.sh")], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "bin/peer_chat_core.py").read_bytes(), (ROOT / "shared/peer-chat/peer_chat_core.py").read_bytes())
            result = subprocess.run([sys.executable, str(root / "bin/peer-chat-paste.py"), "--help"], cwd=root,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_ledger_refuses_a_stale_plan_instead_of_duplicate_id(self):
        code = r'''
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from peer_chat_core import Ledger, LedgerRefusal, now_utc, plan_body
ledger = Ledger(Path(sys.argv[2]))
first = plan_body(["❓ First?"], "left", ledger, now_utc())
stale = plan_body(["❓ Second?"], "left", ledger, now_utc())
ledger.record("left", first, now_utc())
try:
    ledger.record("left", stale, now_utc())
except LedgerRefusal:
    assert len(ledger.load()) == 1
else:
    raise AssertionError("stale ask ID was accepted")
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, "-c", code, str(ROOT / "shared/peer-chat"), str(Path(directory) / "asks.tsv")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_ledger_serializes_plan_through_record_and_ids_over_999(self):
        code = r'''
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from peer_chat_core import Ledger, now_utc, plan_body
ledger = Ledger(Path(sys.argv[2]))
with ledger.locked():
    plan = plan_body(["❓ Concurrent question?"], "left", ledger, now_utc())
    ledger.record("left", plan, now_utc())
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asks.tsv"
            path.write_text("id\tasked_by\tsent_at\tdisposition\tdue\treason\tquestion\nleft-999\tleft\t2026-01-01T00:00:00Z\tanswered\t\tyes\told\n")
            def run(_):
                return subprocess.run([sys.executable, "-c", code, str(ROOT / "shared/peer-chat"), str(path)], capture_output=True, text=True)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(run, range(12)))
            self.assertTrue(all(result.returncode == 0 for result in results), [result.stderr for result in results])
            rows = path.read_text().splitlines()[1:]
            ids = [row.split("\t")[0] for row in rows]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertIn("left-1011", ids)


if __name__ == "__main__":
    unittest.main()
