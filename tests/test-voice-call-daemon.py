import asyncio
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "plugins/voice-call/scripts/voice_call.py"
spec = importlib.util.spec_from_file_location("voice_call", SCRIPT)
vc = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = vc
spec.loader.exec_module(vc)


def registration(session="s1", pane="left", claude="c1", path=None):
    return dict(agterm_session=session, pane=pane, pane_id="surface", claude_session_id=claude,
                transcript_path=path, cwd="/project", title="Test Claude")


def tree():
    return dict(result=dict(tree=dict(workspaces=[dict(sessions=[
        dict(id="s1", foreground=["claude"], splitForeground=["codex"], split=True),
        dict(id="s2", foreground=["claude"], split=False),
        dict(id="s3", foreground=["zsh"], splitForeground=["codex"], split=True),
    ])])))


class DaemonTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="voice-call-")
        async def provider():
            return tree()
        self.daemon = vc.Daemon(dict(vc.DEFAULTS, backend="fake"), self.temp.name, provider)
        self.a = registration()
        self.b = registration("s2", claude="c2")
        await self.daemon.register(self.a)
        await self.daemon.register(self.b)

    async def asyncTearDown(self):
        await self.daemon.hangup_generation(self.daemon.generation)
        self.temp.cleanup()

    async def pin(self):
        return await self.daemon.pin(dict(agterm_session="s1", pane="right"))

    async def test_codex_resolves_only_to_sibling_claude(self):
        result = await self.pin()
        self.assertEqual(result["pinned"]["pane"], "left")
        self.assertEqual(result["pinned"]["claude_session_id"], "c1")

    async def test_no_claude_does_not_disrupt_existing_pin(self):
        await self.pin()
        with self.assertRaises(vc.CallError) as raised:
            await self.daemon.pin(dict(agterm_session="s3", pane="right"))
        self.assertEqual(raised.exception.code, "no_claude_pane")
        self.assertEqual(self.daemon.pinned.agterm_session, "s1")

    async def test_unregistered_refused(self):
        self.daemon.registered.clear()
        with self.assertRaises(vc.CallError) as raised:
            await self.pin()
        self.assertEqual(raised.exception.code, "not_registered")

    async def test_register_idempotent_and_replacement_ends_call(self):
        await self.pin()
        generation = self.daemon.generation
        self.assertTrue((await self.daemon.register(self.a))["pinned"])
        self.assertEqual(self.daemon.generation, generation)
        await self.daemon.register(dict(self.a, claude_session_id="replacement"))
        self.assertIsNone(self.daemon.pinned)

    async def test_turns_only_pinned_once_and_not_aborted(self):
        await self.pin()
        inactive = await self.daemon.turn(dict(self.b, turn_id="b1", answer="Other pane secret", aborted=False))
        self.assertFalse(inactive["spoken"])
        body = dict(self.a, turn_id="a1", answer="Implemented the thing", aborted=False)
        self.assertTrue((await self.daemon.turn(body))["spoken"])
        self.assertFalse((await self.daemon.turn(body))["spoken"])
        self.assertFalse((await self.daemon.turn(dict(body, turn_id="a2", aborted=True)))["spoken"])
        events = [json.loads(row) for row in self.daemon.log.path.read_text().splitlines()]
        summaries = [e for e in events if e.get("type") == "session.commentary.append"]
        self.assertEqual(len(summaries), 1)
        self.assertNotIn("Other pane secret", self.daemon.log.path.read_text())
        self.assertEqual((await self.daemon.run_tool("read_turn", {"index":"last"}))["text"], body["answer"])

    async def test_events_are_private_to_target_and_resume_by_seq(self):
        await self.pin()
        a, b = vc.Pane.parse(self.a), vc.Pane.parse(self.b)
        first = await self.daemon.bus.wait(a, 0, .01)
        self.assertTrue(first["events"])
        self.assertFalse((await self.daemon.bus.wait(b, 0, .01))["events"])
        self.assertFalse((await self.daemon.bus.wait(a, first["seq"], .01))["events"])
        await self.daemon.line("voice", "Hello")
        second = await self.daemon.bus.wait(a, first["seq"], .01)
        self.assertEqual([e["text"] for e in second["events"]], ["Hello"])

    async def test_wait_recovers_after_sequence_reset(self):
        result = await asyncio.wait_for(self.daemon.bus.wait(vc.Pane.parse(self.a), 900), .1)
        self.assertEqual(result, dict(seq=0, events=[]))

    async def test_unregistered_wait_does_not_block_registration(self):
        result = await asyncio.wait_for(self.daemon.dispatch("GET", "/wait?agterm_session=new&pane=left&since=0", {}), .1)
        self.assertEqual(result["events"], [])

    async def test_tool_submit_and_ack_are_private(self):
        await self.pin()
        seq = self.daemon.bus.seq
        task = asyncio.create_task(self.daemon.run_tool("send_to_claude", {"text":"Run tests"}))
        result = await self.daemon.bus.wait(vc.Pane.parse(self.a), seq, .1)
        event = next(e for e in result["events"] if e["kind"] == "submit")
        self.assertFalse((await self.daemon.bus.wait(vc.Pane.parse(self.b), seq, .01))["events"])
        await self.daemon.submit_result(dict(id=event["id"], status="queued"))
        self.assertEqual((await task)["status"], "queued")
        self.assertFalse(any(row[2]["kind"] == "submit" for row in self.daemon.bus.events))
        await self.daemon.submit_result(dict(id=event["id"], status="refused", reason="Session closed"))
        self.assertIn("Correction:", self.daemon.log.path.read_text())

    async def test_submit_timeout_is_not_delivery(self):
        await self.pin()
        self.daemon.submit_timeout = .01
        result = await self.daemon.run_tool("send_to_claude", {"text":"Run tests"})
        self.assertEqual(result["status"], "refused")
        self.assertIn("Not delivered", result["reason"])

    async def test_repin_cancels_pending_and_old_tools(self):
        await self.pin()
        generation = self.daemon.generation
        seq = self.daemon.bus.seq
        task = asyncio.create_task(self.daemon.run_tool("send_to_claude", {"text":"Run tests"}))
        await self.daemon.bus.wait(vc.Pane.parse(self.a), seq, .1)
        await self.daemon.pin(self.b)
        self.assertEqual((await task)["status"], "refused")
        result = await self.daemon.run_tool("send_to_claude", {"text":"Stale instruction"}, generation)
        self.assertEqual(result["status"], "refused")
        self.assertFalse(any(row[2]["kind"] == "submit" for row in self.daemon.bus.events))

    async def test_oversize_prompt_is_refused_before_event(self):
        await self.pin()
        with self.assertRaises(vc.CallError):
            await self.daemon.run_tool("send_to_claude", {"text":"é" * 4097})
        self.assertFalse(any(row[2]["kind"] == "submit" for row in self.daemon.bus.events))

    async def test_http_roundtrip_and_bad_body(self):
        path = str(Path(self.temp.name) / "test.sock")
        server = await asyncio.start_unix_server(lambda r,w: vc.http_connection(r,w,self.daemon), path)
        async with server:
            for payload, expected in [(b"GET /status HTTP/1.1\r\n\r\n", 200),
                                      (b"POST /register HTTP/1.1\r\nContent-Length: 2\r\n\r\n[]", 400)]:
                reader, writer = await asyncio.open_unix_connection(path)
                writer.write(payload)
                await writer.drain()
                raw = await reader.read()
                self.assertIn(f"HTTP/1.1 {expected}".encode(), raw)
                writer.close()
                await writer.wait_closed()

    async def test_auto_falls_back_only_before_started_on_auth(self):
        starts = []
        class Backend(vc.FakeBackend):
            async def start(inner):
                starts.append(inner.name)
                if inner.name == "gpt-live":
                    raise vc.CallError("missing_scope", "scope missing", 502)
        def factory(name, emit, tool, log):
            backend = Backend(self.daemon.config, emit, tool, log)
            backend.name = name
            backend.model = "gpt-realtime-2.1" if name == "realtime" else "gpt-live-1"
            return backend
        self.daemon.config["backend"] = "auto"
        self.daemon.backend_factory = factory
        await self.pin()
        self.assertEqual(starts, ["gpt-live", "realtime"])
        self.assertEqual(self.daemon.status()["backend"], "realtime")
        self.assertIn("GPT-Live unavailable (missing_scope), using realtime", self.daemon.log.path.read_text())

    async def test_explicit_live_does_not_fall_back(self):
        class Backend(vc.FakeBackend):
            async def start(inner):
                raise vc.CallError("missing_scope", "scope missing", 502)
        self.daemon.config["backend"] = "gpt-live"
        self.daemon.backend_factory = lambda name, emit, tool, log: Backend(self.daemon.config, emit, tool, log)
        with self.assertRaises(vc.CallError):
            await self.pin()
        self.assertIsNone(self.daemon.pinned)

    async def test_agterm_tree_skips_saved_closed_windows(self):
        windows = {"result":{"windows":[{"id":"open-window","open":True},{"id":"closed-window","open":False}]}}
        with patch.object(vc, "command_json", new=AsyncMock(side_effect=[windows, tree()])) as command:
            result = await vc.agterm_tree()
            self.assertEqual(len(result), 1)
            self.assertEqual(command.await_count, 2)
            self.assertEqual(command.await_args.args[-1], "open-window")


class TranscriptTests(unittest.TestCase):
    def test_only_user_and_assistant_text_are_searchable(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "session.jsonl"
            data = [dict(type="user", message=dict(content="Question")),
                    dict(type="assistant", message=dict(content=[dict(type="text",text="Answer"),dict(type="thinking",thinking="private")])),
                    dict(type="user", message=dict(content=[dict(type="tool_result",content="secret")])),
                    dict(type="assistant", isSidechain=True, message=dict(content="Subagent secret"))]
            path.write_text("\n".join(json.dumps(item) for item in data) + "\n{partial")
            turns = vc.read_transcript(registration(path=str(path)))
            self.assertEqual([t["text"] for t in turns], ["Question", "Answer"])

    def test_nullable_path_requires_unique_valid_session(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"CLAUDE_CONFIG_DIR":folder}):
            path = Path(folder)/"projects/p/c1.jsonl"
            path.parent.mkdir(parents=True)
            path.write_text("")
            self.assertEqual(vc.transcript_path(registration()), path)
            other = Path(folder)/"projects/q/c1.jsonl"
            other.parent.mkdir()
            other.write_text("")
            self.assertIsNone(vc.transcript_path(registration()))
            with self.assertRaises(vc.CallError):
                vc.transcript_path(registration(claude="../../other"))

    def test_summary_bound_handles_multibyte_text(self):
        self.assertLessEqual(len(vc.summary("😀" * 2000).encode()), 400)

    def test_profile_has_value_source_parity(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, ".voice-call.json").write_text('{"backend":"realtime","voice":"cedar"}')
            profile = vc.load_profile(folder)
            self.assertEqual(set(profile["values"]), set(profile["sources"]))
            self.assertEqual(profile["sources"]["voice"], "profile")
            self.assertEqual(profile["values"]["model"], "gpt-realtime-2.1")


class BackendProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.log = vc.CallLog(Path(self.temp.name))
        self.events, self.tools = [], []
        async def emit(who, text):
            self.events.append((who, text))
        async def tool(name, args):
            self.tools.append((name, args))
            return {"status":"sent"}
        self.backend = vc.NetworkBackend(dict(vc.DEFAULTS), "gpt-live", emit, tool, self.log)
        class Socket:
            sent = []
            async def send(inner, raw):
                inner.sent.append(json.loads(raw))
            async def close(inner):
                pass
        self.backend.ws = Socket()

    async def asyncTearDown(self):
        await self.backend.close()
        self.log.close()
        self.temp.cleanup()

    async def test_live_completed_items_drive_one_tool_continuation(self):
        await self.backend.handle({"type":"response.event","event":{
            "type":"response.output_item.done","item":{"type":"function_call","name":"session_overview","arguments":"{}","call_id":"c"}}})
        self.assertEqual(self.tools, [])
        await self.backend.handle({"type":"response.event","event":{"type":"response.completed","response":{"output":[]}}})
        await asyncio.gather(*self.backend.tasks)
        self.assertEqual(self.tools, [("session_overview", {})])
        self.assertEqual([e["type"] for e in self.backend.ws.sent], ["response.item.create","response.create"])
        self.assertEqual(self.backend.ws.sent[0]["item"]["call_id"], "c")

    async def test_live_stop_flushes_and_suppresses_already_queued_audio(self):
        self.backend.audio.append(b"\x00\x01" * 100)
        await self.backend.stop()
        self.backend.audio.append(b"\x00\x01" * 100)
        self.assertEqual(len(self.backend.audio.pending), 0)
        self.assertEqual(self.backend.ws.sent[-1]["type"], "session.instructions.append")
        await self.backend.handle({"type":"session.input_transcript.delta","delta":"Continue"})
        self.backend.audio.append(b"\x00\x01")
        self.assertEqual(len(self.backend.audio.pending), 2)

    async def test_realtime_stop_cancels_and_truncates_at_played_duration(self):
        self.backend.name = "realtime"
        self.backend.active_response = True
        self.backend.audio_item = "item-1"
        self.backend.audio.played = 2400
        self.backend.audio.append(b"\x00\x01" * 100)
        await self.backend.stop()
        sent = self.backend.ws.sent
        self.assertEqual([e["type"] for e in sent], ["response.cancel", "conversation.item.truncate"])
        self.assertEqual(sent[-1]["audio_end_ms"], 100)
        self.assertTrue(self.backend.audio.muted)
        self.assertEqual(len(self.backend.audio.pending), 0)

    async def test_realtime_barge_in_drops_old_audio_until_new_response(self):
        self.backend.name = "realtime"
        await self.backend.handle({"type":"input_audio_buffer.speech_started"})
        await self.backend.handle({"type":"response.output_audio.delta","delta":"AAE="})
        self.assertEqual(len(self.backend.audio.pending), 0)
        await self.backend.handle({"type":"response.created"})
        await self.backend.handle({"type":"response.output_audio.delta","delta":"AAE="})
        self.assertEqual(len(self.backend.audio.pending), 2)


class ProcessTests(unittest.TestCase):
    def test_key_import_keeps_secret_out_of_process_arguments(self):
        secret = "sentinel-key-not-for-argv"
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)/"key.env"
            source.write_text("OPENAI_API_KEY=" + secret)
            responses = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, stdout=secret)]
            with patch.object(vc.subprocess, "run", side_effect=responses) as run:
                vc.import_key(source)
            self.assertEqual(run.call_args_list[0].args[0], ["security", "-i"])
            self.assertIn(secret, run.call_args_list[0].kwargs["input"])
            for call in run.call_args_list:
                self.assertNotIn(secret, " ".join(call.args[0]))

    def test_key_import_verifies_interactive_command_success(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)/"key.env"
            source.write_text("OPENAI_API_KEY=sentinel")
            responses = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, stdout="old-value")]
            with patch.object(vc.subprocess, "run", side_effect=responses), self.assertRaises(vc.CallError):
                vc.import_key(source)

    def test_link_only_repairs_old_version_without_touching_keymap(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(vc.Path, "home", return_value=Path(folder)):
            link = Path(folder)/".local/bin/voice-call"
            link.parent.mkdir(parents=True)
            link.symlink_to(Path(folder)/"old-version/scripts/voice-call")
            output = io.StringIO()
            with patch.object(vc.subprocess, "run") as run, redirect_stdout(output):
                self.assertEqual(vc.main(["install", "--link-only"]), 0)
                modified = link.lstat().st_mtime_ns
                self.assertEqual(vc.main(["install", "--link-only"]), 0)
            run.assert_not_called()
            self.assertEqual(link.resolve(), SCRIPT.with_name("voice-call"))
            self.assertEqual(link.lstat().st_mtime_ns, modified)
            self.assertEqual(output.getvalue(), "")
            self.assertFalse(Path(folder, ".config").exists())

    def test_install_preserves_keymap_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="vc home '") as folder, patch.object(vc.Path, "home", return_value=Path(folder)):
            path = Path(folder)/".config/agterm/keymap.conf"
            path.parent.mkdir(parents=True)
            original = 'command "Existing" cmd+e echo keep\n'
            path.write_text(original)
            with patch.object(vc.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
                vc.install()
                first = path.read_text()
                vc.install()
            self.assertEqual(first, path.read_text())
            self.assertTrue(first.startswith(original))
            self.assertEqual(first.count("# voice-call v1"), 1)
            self.assertNotIn("@VOICE_CALL@", first)
            self.assertTrue((Path(folder)/".local/bin/voice-call").is_symlink())

    def test_singleton_socket_permissions_and_shutdown(self):
        with tempfile.TemporaryDirectory(prefix="vc-") as folder:
            env = dict(os.environ, VOICE_CALL_STATE_DIR=folder)
            process = subprocess.Popen([sys.executable, str(SCRIPT), "serve", "--backend", "fake"],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                with patch.dict(os.environ, {"VOICE_CALL_STATE_DIR":folder}):
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            result = vc.request("GET", "/status", timeout=.1)
                            break
                        except OSError:
                            self.assertIsNone(process.poll())
                            if time.monotonic() > deadline:
                                self.fail("Daemon failed to create socket")
                            time.sleep(.02)
                    self.assertEqual(result["call"], "idle")
                    self.assertEqual(vc.socket_path().stat().st_mode & 0o777, 0o600)
                    second = subprocess.run([sys.executable, str(SCRIPT), "serve", "--backend", "fake"],
                                            env=env, capture_output=True, timeout=5)
                    self.assertEqual(second.returncode, 4)
                    self.assertTrue(vc.request("GET", "/status")["running"])
            finally:
                process.terminate()
                process.communicate(timeout=5)
            self.assertFalse(Path(folder, "voice.sock").exists())

    def test_detached_spawn_scrubs_all_agterm_variables(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {
            "VOICE_CALL_STATE_DIR":folder, "AGTERM_SESSION_ID":"old", "AGTERM_PANE":"right", "AGTERM_NEW_FIELD":"old"}):
            with patch.object(vc.subprocess, "Popen") as spawn, patch.object(vc, "request", return_value={"running":True}):
                vc.start_detached()
                self.assertFalse(any(key.startswith("AGTERM_") for key in spawn.call_args.kwargs["env"]))
                self.assertTrue(spawn.call_args.kwargs["start_new_session"])


if __name__ == "__main__":
    unittest.main()
