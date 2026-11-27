"""Schema 2 state module: budgets, timers, migrations and per-repo freezes against real files and locks."""

import fcntl
import hashlib
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared/peer-chat"))
sys.dont_write_bytecode = True

import peer_chat_state as ps  # noqa: E402

T0 = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
LEFT = {
    "agent_id": "parent-id",
    "harness": "claude",
    "requested_model": None,
    "pane": "left",
    "session": "S",
    "window": "W",
}
RIGHT = {
    "agent_id": "child-id",
    "harness": "codex",
    "requested_model": "astra",
    "pane": "right",
    "session": "S",
    "window": "W",
}
NO_VALUES = {"deadline": None, "grace": None, "wake": None}


def at(minutes):
    return T0 + timedelta(minutes=minutes)


def budgets(deadline="20m", grace="5m", wake="5m"):
    return ps.resolve_budgets(
        "agterm",
        True,
        flags=NO_VALUES,
        env={},
        profile={},
        estimates={"deadline": deadline, "grace": grace, "wake": wake},
    )


class StateCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.repo = self.dir / "repo"
        self.repo.mkdir()
        self.store = ps.open_topic(
            self.repo / "tmp/peer-chat/topic/state.json",
            transport="agterm",
            slug="topic",
            host="claude",
            repo=self.repo,
        )
        ps.bind_participant(self.store, "left", LEFT)
        ps.bind_participant(self.store, "right", RIGHT)

    def deliver(self, sender, lines, key, chosen=None, minute=0):
        prepared = ps.prepare_message(
            self.store,
            sender=sender,
            lines=lines,
            key=key,
            budgets=chosen,
            width=0,
            now=at(minute),
        )
        self.assertTrue(
            ps.claim_delivery(self.store, prepared["message_id"], now=at(minute))
        )
        ps.observe(self.store, prepared["message_id"], "pasted", now=at(minute))
        ps.observe(self.store, prepared["message_id"], "submit_sent", now=at(minute))
        return prepared

    def blocking_ask(self, minute=0):
        return self.deliver(
            "left", ["🔎 a.py:1", "❓ which one?"], "ask", budgets(), minute
        )



class BudgetTests(unittest.TestCase):
    def resolve(
        self,
        transport="agterm",
        flags=None,
        env=None,
        profile=None,
        estimates=None,
        blocking=True,
    ):
        return ps.resolve_budgets(
            transport,
            blocking,
            flags={**NO_VALUES, **(flags or {})},
            env=env or {},
            profile=profile or {},
            estimates={**NO_VALUES, **(estimates or {})},
        )

    def test_each_value_takes_flag_then_env_then_profile_then_agent(self):
        chosen = self.resolve(
            flags={"deadline": "1h"},
            env={"PEER_CHAT_GRACE_MINUTES": "3"},
            profile={"grace_minutes": 9, "wake_minutes": 2},
            estimates={"deadline": "20m", "grace": "1m", "wake": "4m"},
        )
        self.assertEqual(
            chosen.to_json(),
            {
                "deadline": {"seconds": 3600.0, "source": "flag"},
                "grace": {"seconds": 180.0, "source": "env"},
                "wake": {"seconds": 120.0, "source": "profile"},
            },
        )

    def test_agent_estimate_is_the_last_resort(self):
        chosen = self.resolve(
            estimates={"deadline": "20m", "grace": "90s", "wake": "5m"}
        )
        self.assertEqual({v.source for _, v in chosen.fields()}, {"agent"})

    def test_malformed_values_are_refused_never_changed(self):
        for bad in (
            {"flags": {"deadline": "20"}},
            {"flags": {"deadline": "-5m"}},
            {"flags": {"deadline": "0m"}},
            {"env": {"PEER_CHAT_STALL_MINUTES": "abc"}},
            {"env": {"PEER_CHAT_STALL_MINUTES": "inf"}},
            {"profile": {"stall_minutes": True}},
            {"profile": {"stall_minutes": 0}},
        ):
            with self.subTest(bad=bad), self.assertRaises(ps.StateError):
                self.resolve(
                    estimates={"deadline": "1m", "grace": "1m", "wake": "1m"}, **bad
                )

    def test_blocking_ask_without_deadline_or_grace_is_refused(self):
        with self.assertRaisesRegex(
            ps.StateError, "a blocking ask needs deadline, grace"
        ):
            self.resolve(estimates={"wake": "5m"})

    def test_non_blocking_arms_nothing_and_bg_needs_no_wake(self):
        self.assertIsNone(self.resolve(blocking=False))
        chosen = self.resolve("bg", estimates={"deadline": "20m", "grace": "5m"})
        self.assertIsNone(chosen.wake)

    def test_note_shows_every_field_with_its_own_source(self):
        chosen = self.resolve(
            flags={"grace": "5m"},
            env={"PEER_CHAT_WAKE_MINUTES": "5"},
            estimates={"deadline": "20m"},
        )
        self.assertEqual(
            ps.budget_note(chosen),
            "deadline 20m after submission (agent); "
            "grace 5m after nudge submission (flag); wake 5m (env)",
        )

    def test_round_trip_through_json(self):
        chosen = budgets()
        self.assertEqual(ps.Budgets.from_json(chosen.to_json()), chosen)


class MessageAndTimerTests(StateCase):
    def test_stamp_line_is_metadata_after_the_question(self):
        prepared = ps.prepare_message(
            self.store,
            sender="left",
            lines=["🔎 a.py:1", "❓ which one?"],
            key="k",
            budgets=budgets(),
            width=0,
            now=T0,
        )
        self.assertEqual(
            prepared["text"].splitlines()[-1],
            "⏱ deadline 20m after submission (agent); "
            "grace 5m after nudge submission (agent); wake 5m (agent)",
        )
        self.assertEqual(
            self.store.read()["messages"][prepared["message_id"]]["new_asks"],
            [["left-001", "which one?"]],
        )

    def test_expires_at_is_stored_after_submission_only(self):
        prepared = ps.prepare_message(
            self.store,
            sender="left",
            lines=["❓ q"],
            key="k",
            budgets=budgets(),
            width=0,
            now=T0,
        )
        ps.claim_delivery(self.store, prepared["message_id"], now=at(1))
        ps.observe(self.store, prepared["message_id"], "pasted", now=at(2))
        self.assertEqual(self.store.read()["timers"], {})
        ps.observe(self.store, prepared["message_id"], "submit_sent", now=at(3))
        timer = self.store.read()["timers"]["left-001"]
        self.assertEqual(
            (timer["armed_at"], timer["expires_at"]),
            (ps.stamp(at(3)), ps.stamp(at(23))),
        )

    def test_claim_authorizes_one_paste_only(self):
        prepared = ps.prepare_message(
            self.store,
            sender="left",
            lines=["hi"],
            key="k",
            budgets=None,
            width=0,
            now=T0,
        )
        self.assertTrue(ps.claim_delivery(self.store, prepared["message_id"]))
        self.assertFalse(ps.claim_delivery(self.store, prepared["message_id"]))
        replay = ps.prepare_message(
            self.store, sender="left", lines=["hi"], key="k", budgets=None, width=0
        )
        self.assertTrue(replay["replayed"])
        self.assertFalse(ps.claim_delivery(self.store, replay["message_id"]))

    def test_peer_events_need_the_bound_recipient_and_evidence_inside_the_repo(self):
        prepared = self.deliver("left", ["hi"], "k")
        inside = self.repo / "reply.txt"
        inside.write_text("the peer's reply\n")
        outside = self.dir / "elsewhere.txt"
        outside.write_text("not in the project\n")
        with self.assertRaisesRegex(ps.StateError, "needs the right peer's actor id"):
            ps.observe(self.store, prepared["message_id"], "answered", evidence=inside)
        with self.assertRaisesRegex(ps.StateError, "not the right peer"):
            ps.observe(self.store, prepared["message_id"], "answered", evidence=inside, actor="parent-id")
        with self.assertRaisesRegex(ps.StateError, "inside the project"):
            ps.observe(self.store, prepared["message_id"], "answered", evidence=outside, actor="child-id")
        result = ps.observe(self.store, prepared["message_id"], "answered", evidence=inside, actor="child-id")
        self.assertEqual(result["state"], "answered")

    def test_keystroke_receipts_never_count_as_peer_evidence(self):
        prepared = self.deliver("left", ["hi"], "k")
        with self.assertRaisesRegex(ps.StateError, "needs peer evidence"):
            ps.observe(self.store, prepared["message_id"], "answered")

    def test_evidence_is_a_write_once_copy_that_a_rewritten_source_cannot_change(self):
        prepared = self.deliver("left", ["hi"], "k")
        spool = self.repo / "outbox.msg"
        spool.write_text("the text the peer received\n")
        result = ps.observe(self.store, prepared["message_id"], "answered", evidence=spool, actor="child-id")
        proof = result["events"][-1]["evidence"]
        blob = Path(proof["path"])
        self.assertEqual((blob.parent.name, blob.name), ("evidence", proof["sha256"]))
        self.assertEqual(proof["source"], str(spool.resolve()))
        self.assertEqual(blob.stat().st_mode & 0o777, 0o400)
        spool.write_text("the next send overwrote the spool\n")
        self.assertEqual(blob.read_text(), "the text the peer received\n")
        self.assertTrue(ps.evidence_intact(self.repo, proof))
        copy = self.repo / "same-bytes.txt"
        copy.write_text("the text the peer received\n")
        replay = ps.observe(self.store, prepared["message_id"], "answered", evidence=copy, actor="child-id")
        self.assertTrue(replay["replayed"])

    def test_replay_matches_a_pre_store_record_by_digest(self):
        prepared = self.deliver("left", ["hi"], "k")
        reply = self.repo / "reply.txt"
        reply.write_text("reply\n")
        self.legacy_answer(prepared["message_id"], reply)
        replay = ps.observe(self.store, prepared["message_id"], "answered", evidence=reply, actor="child-id")
        self.assertTrue(replay["replayed"])

    def test_relocation_accepts_only_the_recipient_and_the_exact_original_bytes(self):
        prepared = self.deliver("left", ["hi"], "k")
        spool = self.repo / "outbox.msg"
        spool.write_text("the text the peer received\n")
        original = self.legacy_answer(prepared["message_id"], spool)
        recovered = self.repo / "recovered.txt"
        recovered.write_text("the text the peer received\n")
        relocate = lambda actor="child-id", evidence=recovered: ps.relocate(
            self.store, prepared["message_id"], 2, actor=actor, evidence=evidence, reason="spool overwritten")
        with self.assertRaisesRegex(ps.StateError, "intact; nothing to relocate"):
            relocate()
        spool.write_text("the next send overwrote the spool\n")
        with self.assertRaisesRegex(ps.StateError, "bound recipient who recorded"):
            relocate(actor="parent-id")
        forged = self.repo / "forged.txt"
        forged.write_text("a plausible reconstruction\n")
        with self.assertRaisesRegex(ps.StateError, "exact original bytes"):
            relocate(evidence=forged)
        with self.assertRaisesRegex(ps.StateError, "not a peer receipt|only a peer receipt"):
            ps.relocate(self.store, prepared["message_id"], 0, actor="child-id", evidence=recovered, reason="x")
        moved = relocate()
        event = self.store.read()["messages"][prepared["message_id"]]["events"][2]
        self.assertEqual(event["evidence"], original)
        self.assertEqual(ps.proof_of(event), moved["evidence"])
        self.assertEqual(event["relocations"][0]["reason"], "spool overwritten")
        self.assertTrue(ps.evidence_intact(self.repo, ps.proof_of(event)))

    def legacy_answer(self, message_id: str, path: Path) -> dict:
        """An answered receipt as recorded before the evidence store: a bare live path and its digest."""
        ps.observe(self.store, message_id, "answered", evidence=path, actor="child-id")
        legacy = {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        with self.store.mutate() as state:
            state["messages"][message_id]["events"][-1]["evidence"] = legacy
        return legacy

    def test_blocking_ask_needs_a_bound_recipient(self):
        store = ps.open_topic(
            self.dir / "other/state.json",
            transport="agterm",
            slug="other",
            host="claude",
            repo=self.repo,
        )
        ps.bind_participant(store, "left", LEFT)
        with self.assertRaisesRegex(ps.StateError, "bind the recipient"):
            ps.prepare_message(
                store,
                sender="left",
                lines=["❓ q"],
                key="k",
                budgets=budgets(),
                width=0,
            )

    def test_nudge_grace_stop_release(self):
        self.blocking_ask()
        self.assertEqual(ps.due(self.store, now=at(19)), [])
        [action] = ps.due(self.store, now=at(20))
        self.assertEqual(action["action"], "nudge")
        self.assertIsNotNone(ps.begin(self.store, action["token"], "nudge", now=at(20)))
        self.assertEqual(
            ps.nudge_submitted(self.store, action["token"], now=at(21)),
            ps.stamp(at(26)),
        )
        [stop] = ps.due(self.store, now=at(26))
        self.assertEqual(stop["action"], "stop")
        ps.begin(self.store, stop["token"], "stop", now=at(26))
        ps.finish(self.store, stop["token"], "stop", "ok", now=at(27))
        state = self.store.read()
        self.assertEqual(state["timers"]["left-001"]["phase"], "stopped")
        self.assertEqual(
            state["asks"][0]["timed_out"], {"at": ps.stamp(at(20)), "phase": "stopped"}
        )
        self.assertIn("left-001", ps.status(self.store)["open_asks"])
        proof = self.repo / "quiet.json"
        proof.write_text('{"peer_turn":"idle","jobs":[]}\n')
        self.assertEqual(ps.release(self.store, "left-001", proof)["phase"], "released")

    def test_stale_wake_after_a_stop_is_a_no_op(self):
        self.blocking_ask()
        [action] = ps.due(self.store, now=at(20))
        for field, value in (
            ("timer_gen", 2),
            ("generation", 2),
            ("agent_id", "other"),
            ("run_id", "x"),
        ):
            with self.subTest(field=field):
                self.assertIsNone(
                    ps.begin(
                        self.store,
                        {**action["token"], field: value},
                        "nudge",
                        now=at(20),
                    )
                )
        ps.begin(self.store, action["token"], "nudge", now=at(20))
        ps.nudge_submitted(self.store, action["token"], now=at(20))
        [stop] = ps.due(self.store, now=at(25))
        ps.begin(self.store, stop["token"], "stop", now=at(25))
        ps.finish(self.store, stop["token"], "stop", "ok", now=at(25))
        before = self.store.read()
        self.assertIsNone(ps.begin(self.store, action["token"], "nudge", now=at(40)))
        self.assertIsNone(
            ps.finish(self.store, stop["token"], "nudge", "ok", now=at(40))
        )
        self.assertEqual(self.store.read()["timers"], before["timers"])

    def test_reply_recorded_before_the_wake_lock_wins(self):
        self.blocking_ask()
        [action] = ps.due(self.store, now=at(20))
        self.deliver("right", ["#left-001 answered: the first one"], "reply", minute=20)
        self.assertIsNone(ps.begin(self.store, action["token"], "nudge", now=at(20)))
        state = self.store.read()
        self.assertEqual(state["timers"]["left-001"]["phase"], "cleared")
        self.assertIsNone(state["asks"][0]["timed_out"])
        self.assertEqual(ps.due(self.store, now=at(60)), [])

    def test_crash_between_intent_and_outcome_is_reported_never_repeated(self):
        self.blocking_ask()
        [action] = ps.due(self.store, now=at(20))
        ps.begin(self.store, action["token"], "nudge", now=at(20))
        self.assertEqual(ps.due(self.store, now=at(90)), [])
        self.assertIsNone(ps.begin(self.store, action["token"], "nudge", now=at(90)))
        [intent] = ps.status(self.store)["unresolved_intents"]
        self.assertEqual(
            (intent["ask_id"], intent["action"], intent["outcome"]),
            ("left-001", "nudge", None),
        )

    def test_failed_outcome_stays_reported_and_is_not_retried(self):
        self.blocking_ask()
        [action] = ps.due(self.store, now=at(20))
        ps.begin(self.store, action["token"], "nudge", now=at(20))
        ps.finish(
            self.store,
            action["token"],
            "nudge",
            "failed",
            "SendMessage missing",
            now=at(20),
        )
        self.assertEqual(ps.due(self.store, now=at(90)), [])
        self.assertEqual(
            ps.status(self.store)["unresolved_intents"][0]["outcome"], "failed"
        )

    def test_rearm_is_a_new_timer_gen(self):
        self.blocking_ask()
        [old] = ps.due(self.store, now=at(20))
        ps.rearm(self.store, "left-001", budgets(deadline="1h"), now=at(5))
        self.assertIsNone(ps.begin(self.store, old["token"], "nudge", now=at(20)))
        self.assertEqual(ps.due(self.store, now=at(64)), [])
        self.assertEqual(ps.due(self.store, now=at(65))[0]["token"]["timer_gen"], 2)

    def test_a_wrapped_reason_is_kept_whole(self):
        self.blocking_ask()
        reason = "no, the refund path opens a new bid on every retry after a 409"
        prepared = ps.prepare_message(self.store, sender="right", lines=[f"#left-001 declined({reason})"],
                                      key="wrapped", budgets=None, width=30, now=at(1))
        self.assertGreater(len(prepared["text"].splitlines()), 1)
        ps.claim_delivery(self.store, prepared["message_id"], now=at(1))
        ps.observe(self.store, prepared["message_id"], "pasted", now=at(1))
        ps.observe(self.store, prepared["message_id"], "submit_sent", now=at(1))
        self.assertEqual(self.store.read()["asks"][0]["reason"], reason)

    def stop_peer(self):
        [nudge] = ps.due(self.store, now=at(20))
        ps.begin(self.store, nudge["token"], "nudge", now=at(20))
        ps.nudge_submitted(self.store, nudge["token"], now=at(20))
        [stop] = ps.due(self.store, now=at(25))
        ps.begin(self.store, stop["token"], "stop", now=at(25))
        ps.finish(self.store, stop["token"], "stop", "ok", now=at(25))

    def test_begin_refuses_before_expiry_and_after_the_recipient_changed(self):
        self.blocking_ask()
        [action] = ps.due(self.store, now=at(20))
        self.assertIsNone(ps.begin(self.store, action["token"], "nudge", now=at(19)))
        with self.store.mutate() as state:
            state["participants"]["right"]["generation"] = 2
        self.assertIsNone(ps.begin(self.store, action["token"], "nudge", now=at(20)))
        self.assertIsNone(self.store.read()["timers"]["left-001"]["intent"])

    def test_answer_between_begin_and_finish_keeps_the_timer_cleared(self):
        self.blocking_ask()
        [action] = ps.due(self.store, now=at(20))
        ps.begin(self.store, action["token"], "nudge", now=at(20))
        self.deliver("right", ["#left-001 answered: done"], "reply", minute=20)
        ps.finish(self.store, action["token"], "nudge", "ok", now=at(21))
        timer = self.store.read()["timers"]["left-001"]
        self.assertEqual((timer["phase"], timer["grace_expires_at"], timer["intent"]), ("cleared", None, None))
        self.assertEqual(timer["history"][-1]["outcome"], "ok")
        self.assertEqual(ps.due(self.store, now=at(90)), [])

    def test_a_reply_after_the_stop_is_history_not_an_answer(self):
        self.blocking_ask()
        self.stop_peer()
        reply = self.deliver("right", ["#left-001 answered: late"], "late", minute=40)
        state = self.store.read()
        self.assertEqual(state["asks"][0]["disposition"], "")
        self.assertEqual(state["messages"][reply["message_id"]]["late_dispositions"], ["left-001"])
        self.assertIn("left-001", ps.status(self.store)["open_asks"])

    def test_local_withdraw_closes_a_stopped_ask_without_a_message(self):
        self.blocking_ask()
        self.stop_peer()
        proof = self.repo / "why.txt"
        proof.write_text("the peer stopped; the work went on solo\n")
        messages = len(self.store.read()["messages"])
        with self.assertRaisesRegex(ps.StateError, "only the asker"):
            ps.withdraw(self.store, "left-001", actor="child-id", reason="no", evidence=proof)
        with self.assertRaisesRegex(ps.StateError, "needs a reason"):
            ps.withdraw(self.store, "left-001", actor="parent-id", reason=" ", evidence=proof)
        row = ps.withdraw(self.store, "left-001", actor="parent-id", reason="solo pass", evidence=proof, now=at(41))
        state = self.store.read()
        self.assertEqual((row["disposition"], row["reason"]), ("withdrawn", "solo pass"))
        self.assertEqual(len(state["messages"]), messages)
        self.assertEqual(state["timers"]["left-001"]["phase"], "stopped")
        self.assertNotIn("left-001", ps.status(self.store)["open_asks"])

    def test_on_create_seeds_inside_the_creating_write(self):
        def explode(_state):
            raise ps.StateError("refused while seeding")
        path = self.dir / "seeded/state.json"
        with self.assertRaises(ps.StateError):
            ps.open_topic(path, transport="bg", slug="seeded", host="claude", repo=self.repo, on_create=explode)
        self.assertFalse(path.exists())

    def test_asker_withdraws_its_own_ask_and_clears_the_timer(self):
        self.blocking_ask()
        with self.assertRaisesRegex(ps.StateError, "only the asker"):
            ps.prepare_message(
                self.store,
                sender="right",
                lines=["#left-001 withdrawn(no)"],
                key="w",
                budgets=None,
                width=0,
            )
        self.deliver(
            "left",
            ["#left-001 withdrawn(the peer timed out; solo pass)"],
            "w",
            minute=30,
        )
        state = self.store.read()
        self.assertEqual(
            (state["asks"][0]["disposition"], state["timers"]["left-001"]["phase"]),
            ("withdrawn", "cleared"),
        )

    def test_next_wake_is_never_later_than_the_next_expiry(self):
        self.blocking_ask()
        self.assertEqual(ps.next_wake(self.store, 300, now=at(0)), ps.stamp(at(5)))
        self.assertEqual(ps.next_wake(self.store, 300, now=at(18)), ps.stamp(at(20)))


class StoreTests(StateCase):
    def test_lock_is_released_outside_mutate(self):
        with self.store.mutate():
            with self.store.lock_path.open("a") as other:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with self.store.lock_path.open("a") as other:
            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_a_refusal_writes_nothing(self):
        before = self.store.path.read_bytes()
        with self.assertRaises(ps.StateError):
            ps.bind_participant(
                self.store, "right", {**RIGHT, "agent_id": "someone-else"}
            )
        self.assertEqual(self.store.path.read_bytes(), before)

    def test_no_transport_switch_mid_run(self):
        with self.assertRaisesRegex(ps.StateError, "no transport switch"):
            ps.open_topic(
                self.store.path,
                transport="bg",
                slug="topic",
                host="claude",
                repo=self.repo,
            )


class FreezeTests(StateCase):
    def test_previous_comes_from_the_same_repo(self):
        other = self.dir / "other-repo"
        other.mkdir()
        subprocess.run(["git", "init", "-q", str(other)], check=True)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / "a.py").write_text("a\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=T", "-c", "user.email=t@example.invalid",
                        "commit", "-qm", "base"], check=True)
        head = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()
        first = ps.record_freeze(self.store, self.repo, "tree-a1", ["a.py"])
        second = ps.record_freeze(self.store, other, "tree-b1", ["b.py"])
        third = ps.record_freeze(self.store, self.repo, "tree-a2", ["a.py"])
        fourth = ps.record_freeze(self.store, other / ".", "tree-b2", [])
        self.assertEqual(
            [
                first["previous"],
                second["previous"],
                third["previous"],
                fourth["previous"],
            ],
            [head, ps.EMPTY_TREE, "tree-a1", "tree-b1"],
        )
        self.assertEqual(fourth["repo"], str(other.resolve()))


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)

    def test_bg_schema_1_bumps_in_place_with_source_hash(self):
        path = self.dir / "topic/state.json"
        path.parent.mkdir()
        legacy = {
            "schema": 1,
            "run_id": "r1",
            "slug": "topic",
            "repo": str(self.dir),
            "host": "codex",
            "created_at": "2026-01-01T00:00:00Z",
            "phase": "active",
            "bindings": {"left": {"agent_id": "p", "generation": 1}, "right": None},
            "counters": {"left": 1, "right": 0},
            "keys": {"left:a": "m1"},
            "asks": [
                {
                    "id": "left-001",
                    "asked_by": "left",
                    "sent_at": "x",
                    "disposition": "deferred",
                    "due": "2026-01-01T00:20:00Z",
                    "reason": "later",
                    "question": "q",
                }
            ],
            "messages": {
                "m1": {
                    "message_id": "m1",
                    "sender": "left",
                    "recipient": "right",
                    "text": "❓ q",
                    "new_asks": [["left-001", "q"]],
                    "state": "submitted",
                    "dispositions_applied": True,
                    "asks_active": True,
                    "receipts": [
                        {
                            "state": "dispatching",
                            "at": "t1",
                            "actor_id": "p",
                            "evidence": None,
                        },
                        {
                            "state": "submitted",
                            "at": "t2",
                            "actor_id": "p",
                            "evidence": {"path": "e", "sha256": "s"},
                        },
                    ],
                }
            },
            "checks": {"suite": {"state": "incomplete"}},
            "confirmations": {},
        }
        path.write_text(json.dumps(legacy))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        state = ps.open_topic(
            path, transport="bg", slug="topic", host="codex", repo=self.dir
        ).read()
        self.assertEqual(
            (state["schema"], state["run_id"], state["migrations"][0]["sha256"]),
            (2, "r1", digest),
        )
        self.assertEqual(state["asks"][0]["deferred_due"], "2026-01-01T00:20:00Z")
        self.assertEqual(state["participants"]["left"]["agent_id"], "p")
        message = state["messages"]["m1"]
        self.assertEqual(
            (message["claim"], message["submitted_at"]), ({"at": "t1"}, "t2")
        )

    def test_asks_tsv_imports_once_and_refuses_a_later_conflict(self):
        topic = self.dir / "topic"
        topic.mkdir()
        tsv = topic / "asks.tsv"
        tsv.write_text(
            "id\tasked_by\tsent_at\tdisposition\tdue\treason\tquestion\n"
            "left-001\tleft\tt\tanswered\t\t\tq1\nright-002\tright\tt\t\t\t\tq2\n"
        )
        store = ps.open_topic(
            topic / "state.json",
            transport="agterm",
            slug="topic",
            host="claude",
            repo=self.dir,
            legacy_dir=topic,
        )
        state = store.read()
        self.assertEqual(state["counters"], {"left": 1, "right": 2})
        self.assertEqual([a["id"] for a in state["asks"]], ["left-001", "right-002"])
        ps.open_topic(
            store.path,
            transport="agterm",
            slug="topic",
            host="claude",
            repo=self.dir,
            legacy_dir=topic,
        )
        self.assertEqual(len(store.read()["asks"]), 2)
        with tsv.open("a") as stream:
            stream.write("left-002\tleft\tt\t\t\t\tq3\n")
        with self.assertRaisesRegex(ps.StateError, "changed after its import"):
            ps.open_topic(
                store.path,
                transport="agterm",
                slug="topic",
                host="claude",
                repo=self.dir,
                legacy_dir=topic,
            )

    def test_unimported_tsv_beside_json_asks_is_refused(self):
        topic = self.dir / "topic"
        store = ps.open_topic(
            topic / "state.json",
            transport="agterm",
            slug="topic",
            host="claude",
            repo=self.dir,
        )
        ps.bind_participant(store, "left", LEFT)
        ps.bind_participant(store, "right", RIGHT)
        prepared = ps.prepare_message(
            store, sender="left", lines=["❓ q"], key="k", budgets=None, width=0
        )
        ps.claim_delivery(store, prepared["message_id"])
        (topic / "asks.tsv").write_text(
            "id\tasked_by\tsent_at\tdisposition\tdue\treason\tquestion\n"
        )
        with self.assertRaisesRegex(ps.StateError, "never imported"):
            ps.open_topic(
                store.path,
                transport="agterm",
                slug="topic",
                host="claude",
                repo=self.dir,
                legacy_dir=topic,
            )

    def test_freezes_tsv_becomes_legacy_rows_and_repos_start_a_fresh_baseline(self):
        topic = self.dir / "topic"
        topic.mkdir()
        (topic / "freezes.tsv").write_text(
            "1\t2026-01-01T00:00:00Z\ttree-old\ta.py b.py\n"
        )
        store = ps.open_topic(
            topic / "state.json",
            transport="agterm",
            slug="topic",
            host="claude",
            repo=self.dir,
            legacy_dir=topic,
        )
        [row] = store.read()["freezes"]
        self.assertEqual(
            (row["repo"], row["tree"], row["legacy"], row["pathspecs"]),
            (None, "tree-old", True, ["a.py", "b.py"]),
        )
        self.assertEqual(ps.record_freeze(store, self.dir, "tree-new", [])["previous"], ps.EMPTY_TREE)


if __name__ == "__main__":
    unittest.main()
