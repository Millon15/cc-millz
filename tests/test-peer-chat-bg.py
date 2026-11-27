"""Protocol tests use real subprocesses and filesystem locks, not fake host delivery."""
import concurrent.futures
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "plugins/peer-chat-bg/scripts/peer-chat-bg.py"


class ProtocolFixture(unittest.TestCase):
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


class ProtocolTests(ProtocolFixture):
    def test_cancellation_requires_and_preserves_explanation(self):
        import hashlib
        message = self.prepare("Draft with a typo")
        self.call("receipt", "--message-id", message["message_id"], "--state", "cancelled",
                  "--actor-id", "parent-real-id", status=2)
        result = self.receipt(message, "cancelled")
        proof = result["events"][-1]["evidence"]
        self.assertEqual(proof["sha256"], hashlib.sha256(self.proof.read_bytes()).hexdigest())
        self.assertTrue(self.receipt(message, "cancelled")["replayed"])
        self.proof.write_text("different explanation")
        self.receipt(message, "cancelled", status=2)

    def test_cancellation_cannot_erase_dispatched_questions(self):
        message = self.prepare("❓ Already dispatched?")
        self.receipt(message, "dispatching")
        self.receipt(message, "cancelled", status=2)
        self.assertEqual(len(self.call("status")["open_asks"]), 1)

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

    def test_in_flight_answer_allows_followup_and_both_can_finalize(self):
        self.deliver(self.prepare("❓ A question?"))
        answer = self.prepare("#left-001 answered: yes", "right", "answer")
        followup = self.prepare("A followup without repeating the answer", "right", "followup")
        self.receipt(followup, "dispatching")
        self.receipt(answer, "dispatching")
        self.receipt(answer, "acknowledged")
        self.receipt(followup, "acknowledged")
        self.check()
        self.finalize("parent-real-id")
        self.assertEqual(self.finalize("child-real-id")["phase"], "finalized")

    def test_uncertain_answer_still_counts_as_in_flight(self):
        self.deliver(self.prepare("❓ A question?"))
        answer = self.prepare("#left-001 answered: yes", "right", "answer")
        self.receipt(answer, "dispatching")
        self.receipt(answer, "uncertain")
        followup = self.prepare("An independent followup", "right", "followup")
        self.receipt(followup, "dispatching")
        self.assertEqual(self.call("status")["open_asks"], ["left-001"])

    def test_failed_in_flight_answer_reopens_prepare_and_dispatch_requirements(self):
        self.deliver(self.prepare("❓ A question?"))
        answer = self.prepare("#left-001 answered: yes", "right", "answer")
        followup = self.prepare("An independent followup", "right", "followup")
        self.receipt(answer, "dispatching")
        self.receipt(answer, "failed")
        self.assertIn("no disposition", self.receipt(followup, "dispatching", status=2)["error"])
        result = self.call("prepare", "--sender", "right", "--key", "later", "--stdin",
                           body="Another followup", status=2)
        self.assertIn("no disposition", result["error"])

    def test_cancelled_in_flight_answer_reopens_requirement(self):
        self.deliver(self.prepare("❓ A question?"))
        answer = self.prepare("#left-001 answered: yes", "right", "answer")
        self.receipt(answer, "cancelled")
        result = self.call("prepare", "--sender", "right", "--key", "later", "--stdin",
                           body="Another followup", status=2)
        self.assertIn("no disposition", result["error"])

    def test_stale_disposition_at_dispatch_is_recorded_without_overwriting_answer(self):
        self.deliver(self.prepare("❓ A question?"))
        first = self.prepare("#left-001 answered: first answer", "right", "first")
        second = self.prepare("#left-001 declined(second answer)", "right", "second")
        self.deliver(first)
        dispatched = self.receipt(second, "dispatching")
        self.assertEqual(dispatched["stale_dispositions"], ["left-001"])
        self.receipt(second, "submitted")
        terminal = self.receipt(second, "acknowledged")
        self.assertEqual(terminal["stale_dispositions"], ["left-001"])
        self.assertEqual(terminal["state"], "acknowledged")
        ask = self.call("status")["asks"][0]
        self.assertEqual((ask["disposition"], ask["reason"]), ("answered", "first answer"))

    def test_stale_disposition_at_terminal_receipt_is_recorded(self):
        self.deliver(self.prepare("❓ A question?"))
        first = self.prepare("#left-001 declined(already checked)", "right", "first")
        second = self.prepare("#left-001 answered: yes", "right", "second")
        self.receipt(second, "dispatching")
        self.deliver(first)
        terminal = self.receipt(second, "answered")
        self.assertEqual(terminal["state"], "answered")
        self.assertEqual(terminal["stale_dispositions"], ["left-001"])
        self.assertEqual(self.call("status")["asks"][0]["disposition"], "declined")

    def test_hand_back_activates_asks_applies_dispositions_and_records_recipient(self):
        self.deliver(self.prepare("❓ A question?"))
        for observed in ("acknowledged", "answered"):
            with self.subTest(observed=observed):
                body = "#left-001 answered: yes\n❓ A followup?" if observed == "acknowledged" else "A final result"
                message = self.prepare(body, "right", observed)
                self.assertIn("left", self.receipt(message, observed, actor="child-real-id", status=2)["error"])
                terminal = self.receipt(message, observed)
                self.assertEqual(terminal["state"], observed)
                self.assertTrue(terminal["asks_active"])
                self.assertTrue(terminal["dispositions_applied"])
                self.assertEqual(terminal["recipient_binding"], {"agent_id": "parent-real-id", "generation": 1})
                self.assertEqual(terminal["events"][-1]["via"], "hand-back")
                self.assertTrue(self.receipt(message, observed)["replayed"])
        self.assertEqual(self.call("status")["open_asks"], ["right-001"])

    def test_hand_back_requires_evidence(self):
        message = self.prepare("The returned result", "right", "result")
        result = self.call("receipt", "--message-id", message["message_id"], "--state", "acknowledged",
                           "--actor-id", "parent-real-id", status=2)
        self.assertIn("requires --evidence", result["error"])
        self.assertEqual(self.call("status")["messages"][message["message_id"]]["state"], "prepared")

    def test_hand_back_does_not_recheck_new_missing_dispositions(self):
        result = self.prepare("An already returned result", "right", "early")
        self.deliver(self.prepare("❓ A later question?"))
        self.receipt(result, "acknowledged")
        self.assertEqual(self.call("status")["open_asks"], ["left-001"])
        refused = self.call("prepare", "--sender", "right", "--key", "later", "--stdin",
                            body="No answer yet", status=2)
        self.assertIn("no disposition", refused["error"])

    def test_closing_message_without_asks_keeps_confirmation_and_can_finalize(self):
        self.exchange()
        self.check()
        self.finalize("parent-real-id")
        closing = self.prepare("🏁 Checks and review complete", "right", "close")
        self.assertIn("left", self.call("status")["confirmations"])
        self.deliver(closing)
        self.assertEqual(self.finalize("child-real-id")["phase"], "finalized")

    def test_plain_message_clears_confirmation(self):
        self.exchange()
        self.check()
        self.finalize("parent-real-id")
        self.prepare("One more finding", "right", "finding")
        self.assertEqual(self.call("status")["confirmations"], {})

    def test_closing_message_with_new_ask_clears_confirmation(self):
        self.exchange()
        self.check()
        self.finalize("parent-real-id")
        self.prepare("🏁 Almost done\n❓ One more question?", "right", "question")
        self.assertEqual(self.call("status")["confirmations"], {})

    def test_fast_ack_accepts_late_submission_receipt_without_downgrading(self):
        for observed in ("acknowledged", "answered"):
            message = self.prepare("A message without asks", key=observed)
            self.receipt(message, "dispatching")
            self.receipt(message, observed)
            late = self.receipt(message, "submitted")
            self.assertEqual(late["state"], observed)
            self.assertFalse(late["dispatch_permitted"])
            self.assertEqual(late["events"][-1]["event"], "submitted")
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
        self.assertEqual(len(self.call("status")["messages"][message["message_id"]]["events"]), 2)

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

    def test_refreeze_since_names_only_changed_files_and_a_tree(self):
        (self.repo / "app.txt").write_text("version two\n")
        (self.repo / "new.txt").write_text("new untracked\n")
        refrozen = self.call("target", "--output", "tmp/peer-chat-bg/target-2.json", "--since", self.target)
        self.assertEqual(refrozen["changed"], ["app.txt", "new.txt"])
        self.assertRegex(refrozen["tree"], r"^[0-9a-f]{40}$")
        self.call("target", "--output", "tmp/peer-chat-bg/target-3.json", "--since", "manifest:none.json#" + "0" * 64, status=2)
        self.assertFalse((self.repo / "tmp/peer-chat-bg/target-3.json").exists())

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

    def test_rewritten_source_keeps_the_stored_check_proof_but_a_changed_copy_blocks_finalization(self):
        self.exchange()
        stored = Path(self.check()["evidence"]["path"])
        self.assertEqual(stored.parent.name, "evidence")
        self.proof.write_text("a later run rewrote the source")
        self.finalize("parent-real-id")
        stored.chmod(0o600)
        stored.write_text("forged check output")
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


class BudgetTimerCliTests(ProtocolFixture):

    def blocking(self, *flags, text="🔎 a.py:1\n❓ Which file?", key="blocking", status=0):
        return self.call("prepare", "--sender", "left", "--key", key, "--blocking", *flags, "--stdin",
                         body=text, status=status)

    def test_blocking_prepare_needs_budgets_and_stamps_each_source(self):
        self.assertIn("a blocking ask needs deadline, grace", self.blocking(status=2)["error"])
        self.assertIn("malformed duration", self.blocking("--deadline", "20", "--grace", "5m", status=2)["error"])
        self.assertIn("malformed duration", self.blocking("--est-deadline", "1m", "--grace", "5m", "--wake", "5",
                                                          status=2)["error"])
        ignored = self.blocking("--est-deadline", "20m", "--grace", "5m", "--wake", "5m", "--est-wake", "1m",
                                key="ignored-wake")
        self.assertIsNone(ignored["budgets"]["wake"])
        message = self.blocking("--est-deadline", "20m", "--grace", "5m")
        self.assertEqual(message["text"].splitlines()[-1],
                         "⏱ deadline 20m after submission (agent); grace 5m after nudge submission (flag)")
        self.assertEqual(message["budgets"]["deadline"], {"seconds": 1200.0, "source": "agent"})
        self.assertNotIn("left-001", self.call("status")["timers"])

    def test_timer_cycle_wake_begin_nudged_stop_release(self):
        message = self.blocking("--est-deadline", "1s", "--est-grace", "1s")
        self.receipt(message, "dispatching")
        self.receipt(message, "submitted")
        time.sleep(1.2)
        [nudge] = self.call("wake")["due"]
        token = json.dumps(nudge["token"])
        stale = json.dumps({**nudge["token"], "timer_gen": 9})
        self.assertIsNone(self.call("begin", "--token", stale, "--action", "nudge")["intent"])
        self.assertEqual(self.call("begin", "--token", token, "--action", "nudge")["intent"]["action"], "nudge")
        self.assertIsNone(self.call("begin", "--token", token, "--action", "nudge")["intent"])
        self.call("nudged", "--token", token)
        time.sleep(1.2)
        [stop] = self.call("wake")["due"]
        self.assertEqual(stop["action"], "stop")
        self.call("begin", "--token", json.dumps(stop["token"]), "--action", "stop")
        self.call("finish", "--token", json.dumps(stop["token"]), "--action", "stop", "--outcome", "ok")
        state = self.call("status")
        self.assertEqual((state["timers"]["left-001"]["phase"], state["asks"][0]["timed_out"]["phase"]),
                         ("stopped", "stopped"))
        self.assertEqual(self.call("release", "--ask-id", "left-001", "--evidence", str(self.proof))["timer"]["phase"],
                         "released")

    def test_lock_is_free_between_dispatching_and_the_native_result(self):
        message = self.prepare("hello")
        self.receipt(message, "dispatching")
        with (self.repo / "tmp/peer-chat-bg/topic/state.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lock, fcntl.LOCK_UN)
        self.receipt(message, "submitted")

    def test_rejected_init_leaves_no_topic(self):
        command = [sys.executable, str(HELPER), "--repo", str(self.repo), "--slug", "fresh", "init", "--host", "codex"]
        refused = subprocess.run(command + ["--parent-id", " "], capture_output=True, text=True)
        self.assertEqual(refused.returncode, 2)
        self.assertFalse((self.repo / "tmp/peer-chat-bg/fresh/state.json").exists())
        done = subprocess.run(command + ["--parent-id", "parent-real-id"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["participants"]["left"]["agent_id"], "parent-real-id")

    def test_withdraw_is_local_and_only_for_the_asker(self):
        self.deliver(self.prepare("❓ Still needed?"))
        args = ("withdraw", "--ask-id", "left-001", "--reason", "solo pass", "--evidence", str(self.proof))
        self.assertIn("only the asker", self.call(*args, "--actor-id", "child-real-id", status=2)["error"])
        messages = len(self.call("status")["messages"])
        self.assertEqual(self.call(*args, "--actor-id", "parent-real-id")["ask"]["disposition"], "withdrawn")
        state = self.call("status")
        self.assertEqual((state["open_asks"], len(state["messages"])), ([], messages))

    def test_schema_1_topic_migrates_on_its_first_mutating_command(self):
        path = self.repo / "tmp/peer-chat-bg/legacy/state.json"
        path.parent.mkdir(parents=True)
        legacy = {"schema": 1, "run_id": "r1", "slug": "legacy", "repo": str(self.repo.resolve()), "host": "codex",
                  "created_at": "2026-01-01T00:00:00Z", "phase": "active",
                  "bindings": {"left": {"agent_id": "parent-real-id", "generation": 1},
                               "right": {"agent_id": "child-real-id", "generation": 1}},
                  "counters": {"left": 0, "right": 0}, "messages": {}, "keys": {}, "asks": [],
                  "checks": {"suite": {"state": "incomplete"}}, "confirmations": {}}
        path.write_text(json.dumps(legacy))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        command = [sys.executable, str(HELPER), "--repo", str(self.repo), "--slug", "legacy", "--run", "r1"]
        refused = subprocess.run(command + ["status"], capture_output=True, text=True)
        self.assertIn("schema 1", json.loads(refused.stderr)["error"])
        done = subprocess.run(command + ["prepare", "--sender", "left", "--key", "k", "--stdin"], input="❓ Migrated?",
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        state = json.loads(subprocess.run(command + ["status"], capture_output=True, text=True).stdout)
        self.assertEqual((state["schema"], state["migrations"][0]["sha256"]), (2, digest))
        self.assertEqual(state["participants"]["right"]["agent_id"], "child-real-id")


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


class ScopedTargetTests(ProtocolFixture):
    def scoped(
        self, *paths, output="tmp/peer-chat-bg/scoped.json", status=0, since=None
    ):
        flags = [flag for path in paths for flag in ("--path", path)]
        extra = ["--since", since] if since else []
        return self.call("target", "--output", output, *flags, *extra, status=status)

    def unreadable(self, name):
        path = self.repo / name
        path.write_text("outside the scope\n")
        path.chmod(0)
        self.addCleanup(path.chmod, 0o600)
        return path

    def manifest(self, output="tmp/peer-chat-bg/scoped.json"):
        return json.loads((self.repo / output).read_text())

    def test_scoped_target_checks_beside_an_unreadable_file(self):
        self.unreadable("secret.env")
        scoped = self.scoped("app.txt")
        self.assertRegex(scoped["tree"], r"^[0-9a-f]{40}$")
        self.assertEqual(self.check(target=scoped["target"])["state"], "passed")

    def test_scoped_target_sees_edits_inside_its_paths_only(self):
        target = self.scoped("app.txt")["target"]
        (self.repo / "other.txt").write_text("outside\n")
        self.check(target=target)
        (self.repo / "app.txt").write_text("version two\n")
        self.assertIn(
            "working tree changed", self.check(target=target, status=2)["error"]
        )

    def test_scoped_manifest_binds_sorted_paths_and_unscoped_keeps_its_shape(self):
        (self.repo / "dir").mkdir()
        (self.repo / "dir/f.txt").write_text("f\n")
        self.scoped("dir", "app.txt")
        manifest = self.manifest()
        self.assertEqual(manifest["paths"], ["app.txt", "dir"])
        self.assertEqual(sorted(manifest["files"]), ["app.txt", "dir/f.txt"])
        self.assertNotIn("paths", self.manifest("tmp/peer-chat-bg/target.json"))

    def test_scope_paths_must_be_unique_relative_and_inside_the_repo(self):
        for bad in (
            ["/etc/passwd"],
            ["../outside"],
            ["dir/../../x"],
            [""],
            ["app.txt", "app.txt"],
        ):
            error = self.scoped(*bad, output="tmp/peer-chat-bg/bad.json", status=2)[
                "error"
            ]
            self.assertIn("path", error)
            self.assertFalse((self.repo / "tmp/peer-chat-bg/bad.json").exists())

    def test_each_scope_path_must_match_a_visible_file(self):
        (self.repo / "ignored.txt").write_text("ignored\n")
        (self.repo / ".gitignore").write_text("/tmp/peer-chat-bg/\n/ignored.txt\n")
        for paths in (["app.txt", "future.txt"], ["ignored.txt"]):
            error = self.scoped(*paths, output="tmp/peer-chat-bg/none.json", status=2)["error"]
            self.assertIn(paths[-1] + " matches no visible file", error)
            self.assertFalse((self.repo / "tmp/peer-chat-bg/none.json").exists())

    def test_scoped_file_through_a_symlinked_parent_is_refused(self):
        (self.repo / "src").mkdir()
        (self.repo / "src/code.txt").write_text("lane\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "src/code.txt"], check=True)
        target = self.scoped("src/code.txt")["target"]
        outside = Path(self.temp.name + "-outside")
        outside.mkdir()
        self.addCleanup(shutil.rmtree, outside)
        (outside / "code.txt").write_text("lane\n")
        (self.repo / "src").rename(self.repo / "real-src")
        (self.repo / "src").symlink_to(outside)
        self.assertIn(
            "symlinked directory", self.check(target=target, status=2)["error"]
        )

    def test_since_across_scopes_is_refused(self):
        first = self.scoped("app.txt")["target"]
        error = self.scoped(
            "app.txt",
            ".gitignore",
            output="tmp/peer-chat-bg/s2.json",
            since=first,
            status=2,
        )["error"]
        self.assertIn("different scope", error)
        self.assertIn(
            "different scope",
            self.call(
                "target",
                "--output",
                "tmp/peer-chat-bg/s3.json",
                "--since",
                first,
                status=2,
            )["error"],
        )
        again = self.scoped("app.txt", output="tmp/peer-chat-bg/s4.json", since=first)
        self.assertEqual(again["changed"], [])


if __name__ == "__main__":
    unittest.main()
