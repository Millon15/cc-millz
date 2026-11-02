import asyncio
from contextlib import redirect_stdout, redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "plugins/voice-call/scripts/voice_call.py"
sys.path.insert(0, str(SCRIPT.parent))
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
        self.rules_mock = patch.object(vc, "WorkspaceRules")
        self.rules_type = self.rules_mock.start()
        self.rules_type.return_value.primer.return_value = "Workspace: test. Use read_workspace_rules."
        self.rules_type.return_value.catalog.return_value = {"files": [], "truncated": False}
        async def provider():
            return tree()
        self.daemon = vc.Daemon(dict(vc.DEFAULTS, backend="fake"), self.temp.name, provider)
        self.a = registration()
        self.b = registration("s2", claude="c2")
        await self.daemon.register(self.a)
        await self.daemon.register(self.b)

    async def asyncTearDown(self):
        await self.daemon.hangup_generation(self.daemon.generation)
        self.rules_mock.stop()
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
        await self.daemon.backend.emit("you", "Run tests")
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
        await self.daemon.backend.emit("you", "Run tests")
        self.daemon.submit_timeout = .01
        result = await self.daemon.run_tool("send_to_claude", {"text":"Run tests"})
        self.assertEqual(result["status"], "refused")
        self.assertIn("Not delivered", result["reason"])

    async def test_repin_cancels_pending_and_old_tools(self):
        await self.pin()
        await self.daemon.backend.emit("you", "Run tests")
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
        await self.daemon.backend.emit("you", "Run tests")
        with self.assertRaises(vc.CallError):
            await self.daemon.run_tool("send_to_claude", {"text":"é" * 4097})
        self.assertFalse(any(row[2]["kind"] == "submit" for row in self.daemon.bus.events))

    async def test_forwarding_needs_no_prior_user_speech(self):
        await self.pin()
        with patch.object(self.daemon, "send_to_claude", new=AsyncMock(return_value={"status":"sent"})) as send:
            result = await self.daemon.run_tool("send_to_claude", {"text":"Run tests"})
            self.assertEqual(result, {"status":"sent"})
            send.assert_awaited_once_with("Run tests")

    async def test_pin_announces_defaults(self):
        await self.pin()
        events = await self.daemon.bus.wait(vc.Pane.parse(self.a), 0, .01)
        self.assertTrue(any(event.get("who") == "system" and event.get("text") == "Configuration: defaults"
                            for event in events["events"]))

    async def test_pin_announces_actual_startup_profile(self):
        path = str(Path(self.temp.name)/".voice-call.json")
        daemon = vc.Daemon(dict(vc.DEFAULTS, backend="fake"), self.temp.name,
                          self.daemon.tree_provider, profile_file=path)
        try:
            await daemon.register(self.a)
            await daemon.pin(self.a)
            events = await daemon.bus.wait(vc.Pane.parse(self.a), 0, .01)
            self.assertTrue(any(event.get("text") == "Configuration: " + path for event in events["events"]))
        finally:
            await daemon.hangup_generation(daemon.generation)

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

    async def test_workspace_tool_catalog_search_and_primer_follow_pin(self):
        await self.pin()
        rules = self.rules_type.return_value
        rules.search.return_value = {"matches": [{"path":"CLAUDE.md", "line":1, "text":"Rules"}], "truncated":False}
        self.assertEqual(await self.daemon.run_tool("read_workspace_rules", {}), rules.catalog.return_value)
        self.assertEqual(await self.daemon.run_tool("read_workspace_rules", {"query":"deploy"}), rules.search.return_value)
        rules.search.assert_called_once_with("deploy")
        self.assertIn("Workspace: test", self.daemon.log.path.read_text())
        first = self.daemon.workspace_rules
        self.rules_type.return_value = Mock(primer=Mock(return_value="Workspace: second"))
        await self.daemon.pin(self.b)
        self.assertIsNot(first, self.daemon.workspace_rules)
        await self.daemon.hangup_generation(self.daemon.generation)
        self.assertIsNone(self.daemon.workspace_rules)

    async def test_workspace_results_are_discarded_when_pin_changes_during_read(self):
        await self.pin()
        started, finish = vc.threading.Event(), vc.threading.Event()
        def read():
            started.set()
            finish.wait(2)
            return {"files": [{"path":"old-workspace"}], "truncated": False}
        self.rules_type.return_value.catalog.side_effect = read
        task = asyncio.create_task(self.daemon.run_tool("read_workspace_rules", {}))
        try:
            await asyncio.to_thread(started.wait, 2)
            await self.daemon.pin(self.b)
        finally:
            finish.set()
        self.assertEqual((await task)["status"], "refused")

    async def test_workspace_query_schema_matches_helper_limit(self):
        await self.pin()
        with self.assertRaises(vc.CallError):
            await self.daemon.run_tool("read_workspace_rules", {"query":"x" * 201})
        tool = next(tool for tool in vc.tool_specs() if tool["name"] == "read_workspace_rules")
        self.assertEqual(tool["parameters"]["properties"]["query"]["maxLength"], 200)

    async def test_two_audio_failures_preserve_first_error_and_report_final_devices(self):
        audio_api, operations = fake_audio_api([PortAudioError("first open"), PortAudioError("second open")])
        class Backend(vc.FakeBackend):
            def __init__(inner, config, emit, tool, log):
                super().__init__(config, emit, tool, log)
                inner.audio = vc.Audio()
            async def start(inner):
                await inner.audio.start(lambda raw: None, report=lambda message: inner.emit("system", message))
            async def close(inner):
                inner.audio.close()
        self.daemon.backend_factory = lambda name, emit, tool, log: Backend(self.daemon.config, emit, tool, log)
        with patch.dict(sys.modules, {"sounddevice":audio_api}), patch.object(vc.asyncio, "sleep", new=AsyncMock()) as sleep, redirect_stderr(io.StringIO()) as stderr:
            with self.assertRaises(vc.CallError) as caught:
                await self.pin()
        self.assertEqual(caught.exception.code, "PortAudioError")
        sleep.assert_awaited_once_with(1)
        self.assertEqual(operations.count("open"), 2)
        self.assertIn("first open", stderr.getvalue())
        self.assertIn("Call failed: PortAudioError: open: second open", stderr.getvalue())
        self.assertIn("(in: Test Microphone, out: Test Speakers)", stderr.getvalue())
        logs = "".join(path.read_text() for path in Path(self.temp.name, "calls").glob("*.jsonl"))
        self.assertIn("first open", logs)
        self.assertIn("Call failed: PortAudioError", logs)

    async def test_audio_retry_success_leaves_call_live(self):
        audio_api, operations = fake_audio_api([PortAudioError("first open"), None])
        class Backend(vc.FakeBackend):
            async def start(inner):
                inner.audio = vc.Audio()
                await inner.audio.start(lambda raw: None, report=lambda message: inner.emit("system", message))
            async def close(inner):
                inner.audio.close()
        self.daemon.backend_factory = lambda name, emit, tool, log: Backend(self.daemon.config, emit, tool, log)
        with patch.dict(sys.modules, {"sounddevice":audio_api}), patch.object(vc.asyncio, "sleep", new=AsyncMock()), redirect_stderr(io.StringIO()):
            await self.pin()
        self.assertEqual(self.daemon.call, "live")
        self.assertIn("first open", self.daemon.log.path.read_text())
        self.assertEqual(operations.count("open"), 2)


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

    def test_idle_limit_accepts_120_and_rejects_more(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/".voice-call.json"
            path.write_text('{"idle_hangup_min":120}')
            self.assertEqual(vc.load_profile(folder)["values"]["idle_hangup_min"], 120)
            for idle in (120.01, 121, 100000):
                with self.subTest(idle=idle):
                    path.write_text(json.dumps({"idle_hangup_min":idle}))
                    with self.assertRaises(vc.CallError):
                        vc.load_profile(folder)


    def test_default_voice_is_ripple_without_user_config(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"VOICE_CALL_CONFIG": str(Path(folder, "none.toml"))}):
            profile = vc.load_profile(folder)
            self.assertEqual((profile["values"]["voice"], profile["sources"]["voice"]), ("ripple", "default"))
            self.assertIsNone(profile["user_file"])

    def test_user_config_sits_under_repo_profile(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"VOICE_CALL_CONFIG": str(Path(folder, "config.toml"))}):
            Path(folder, "config.toml").write_text('voice = "ballad"\nidle_hangup_min = 5\n')
            profile = vc.load_profile(folder)
            self.assertEqual((profile["values"]["voice"], profile["sources"]["voice"]), ("ballad", "user"))
            Path(folder, ".voice-call.json").write_text('{"voice":"cedar"}')
            profile = vc.load_profile(folder)
            self.assertEqual((profile["values"]["voice"], profile["sources"]["voice"]), ("cedar", "profile"))
            self.assertEqual((profile["values"]["idle_hangup_min"], profile["sources"]["idle_hangup_min"]), (5, "user"))
            self.assertEqual(vc.config_label(profile), str(Path(folder, "config.toml")) + " + " + str(Path(folder).resolve() / ".voice-call.json"))

    def test_invalid_user_config_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"VOICE_CALL_CONFIG": str(Path(folder, "config.toml"))}):
            for body in ('voice = ', 'unknown = 1', 'idle_hangup_min = 500'):
                with self.subTest(body=body):
                    Path(folder, "config.toml").write_text(body)
                    with self.assertRaises(vc.CallError):
                        vc.load_profile(folder)

    def test_audio_selectors_are_user_only_and_require_strings(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"VOICE_CALL_CONFIG": str(Path(folder, "config.toml"))}):
            Path(folder, "config.toml").write_text('input_device = "Test Microphone"\n')
            profile = vc.load_profile(folder)
            self.assertEqual(profile["values"]["input_device"], "Test Microphone")
            self.assertEqual(profile["sources"]["input_device"], "user")
            self.assertEqual(profile["sources"]["output_device"], "default")
            for key in ("input_device", "output_device"):
                Path(folder, ".voice-call.json").write_text(json.dumps({key:""}))
                with self.subTest(key=key), self.assertRaises(vc.CallError) as error:
                    vc.load_profile(folder)
                self.assertEqual(error.exception.code, "invalid_profile")
            Path(folder, ".voice-call.json").write_text("{}")
            Path(folder, "config.toml").write_text('input_device = 42\n')
            with self.assertRaises(vc.CallError):
                vc.load_profile(folder)

    def test_template_parses_to_the_builtin_voice_and_seeds_once(self):
        template = SCRIPT.with_name("config.toml.template")
        self.assertEqual(vc.tomllib.loads(template.read_text()), {"voice": vc.DEFAULTS["voice"]})
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"VOICE_CALL_CONFIG": str(Path(folder, "sub/config.toml"))}):
            vc.seed_user_config(template)
            target = Path(folder, "sub/config.toml")
            target.write_text('voice = "ballad"\n')
            vc.seed_user_config(template)
            self.assertEqual(target.read_text(), 'voice = "ballad"\n')

class PortAudioError(Exception):
    pass


def fake_audio_api(outcomes, *, start_error=None, stop_error=None):
    operations = []
    devices = [dict(name="Test Microphone", max_input_channels=1, max_output_channels=0, default_samplerate=48000),
               dict(name="Test Speakers", max_input_channels=0, max_output_channels=2, default_samplerate=48000)]
    class Stream:
        def start(self):
            operations.append("start")
            if start_error and operations.count("start") == 1:
                raise start_error
        def stop(self):
            operations.append("stop")
            if stop_error:
                raise stop_error
        def close(self):
            operations.append("close")
    def open_stream(**kwargs):
        operations.append("open")
        result = outcomes.pop(0)
        if result:
            raise result
        return Stream()
    def query():
        operations.append("resolve")
        return devices
    api = SimpleNamespace(PortAudioError=PortAudioError, default=SimpleNamespace(device=(0, 1)),
                          query_devices=Mock(side_effect=query), RawStream=Mock(side_effect=open_stream),
                          _terminate=Mock(side_effect=lambda: operations.append("terminate")),
                          _initialize=Mock(side_effect=lambda: operations.append("initialize")))
    return api, operations


class AudioTests(unittest.IsolatedAsyncioTestCase):
    async def test_retry_closes_partial_start_before_refresh_and_resolves_again(self):
        api, operations = fake_audio_api([None, None], start_error=PortAudioError("start failed"), stop_error=RuntimeError("cleanup failed"))
        async def delay(seconds):
            operations.append("sleep")
        audio = vc.Audio()
        with patch.dict(sys.modules, {"sounddevice":api}), patch.object(vc.asyncio, "sleep", new=AsyncMock(side_effect=delay)) as sleep, redirect_stderr(io.StringIO()) as stderr:
            await audio.start(lambda raw: None)
            audio.close()
        sleep.assert_awaited_once_with(1)
        self.assertEqual(operations[:10], ["resolve", "open", "start", "stop", "close", "sleep", "terminate", "initialize", "resolve", "open"])
        self.assertIn("start: start failed", stderr.getvalue())
        self.assertIn("cleanup failed", stderr.getvalue())
        self.assertEqual(api.RawStream.call_args.kwargs["device"], (0, 1))
        self.assertEqual(api.RawStream.call_args.kwargs["samplerate"], 24000)

    async def test_non_portaudio_error_is_not_retried(self):
        api, operations = fake_audio_api([RuntimeError("callback setup failed")])
        with patch.dict(sys.modules, {"sounddevice":api}), patch.object(vc.asyncio, "sleep", new=AsyncMock()) as sleep, redirect_stderr(io.StringIO()):
            with self.assertRaises(vc.CallError) as caught:
                await vc.Audio().start(lambda raw: None)
        self.assertEqual(caught.exception.code, "RuntimeError")
        self.assertIn("callback setup failed", caught.exception.detail)
        sleep.assert_not_awaited()
        api._terminate.assert_not_called()
        self.assertEqual(operations.count("open"), 1)

    async def test_resolver_is_directional_unique_and_case_insensitive(self):
        api, _ = fake_audio_api([])
        source, destination = vc.resolve_audio_devices("MICROPHONE", "speakers", api)
        self.assertEqual((source.index, destination.index), (0, 1))
        for query, expected in [("Test", "several"), ("Missing", "none")]:
            devices = [vc.AudioDevice(0, "Test A", 1, 0, 48000), vc.AudioDevice(1, "Test B", 1, 0, 48000)]
            with self.subTest(query=query), self.assertRaises(vc.CallError) as caught:
                vc.select_audio_device(devices, "input", query, 0)
            self.assertEqual(caught.exception.code, "audio_device")
            self.assertIn("matches " + expected, caught.exception.detail)
            self.assertIn("Test A", caught.exception.detail)
            self.assertIn("Test B", caught.exception.detail)

    async def test_devices_cli_json_and_portaudio_failure_exit(self):
        api, _ = fake_audio_api([])
        with patch.dict(sys.modules, {"sounddevice":api}), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(vc.main(["devices"]), 0)
        listing = json.loads(output.getvalue())
        self.assertEqual(listing["default_input"], "Test Microphone")
        self.assertEqual(listing["default_output"], "Test Speakers")
        self.assertEqual(set(listing["devices"][0]), {"index", "name", "inputs", "outputs", "default_samplerate"})
        api.query_devices.side_effect = PortAudioError("device enumeration failed")
        with patch.dict(sys.modules, {"sounddevice":api}), redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(vc.main(["devices"]), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("device enumeration failed", stderr.getvalue())


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

    async def test_network_start_awaits_audio_with_user_device_selectors(self):
        self.backend.config.update(input_device="Chosen Mic", output_device="Chosen Speaker")
        websocket = self.backend.ws
        transport = SimpleNamespace(connect=AsyncMock(return_value=websocket))
        with patch.dict(sys.modules, {"websockets":transport}), patch.object(vc, "read_key", return_value="test-key"), \
             patch.object(self.backend, "handshake", new=AsyncMock()), \
             patch.object(self.backend.audio, "start", new=AsyncMock()) as start:
            await self.backend.start()
        start.assert_awaited_once()
        self.assertEqual(start.call_args.kwargs["input_device"], "Chosen Mic")
        self.assertEqual(start.call_args.kwargs["output_device"], "Chosen Speaker")
        self.assertTrue(callable(start.call_args.kwargs["report"]))

    async def test_start_cleanup_error_does_not_replace_original_failure(self):
        transport = SimpleNamespace(connect=AsyncMock(return_value=self.backend.ws))
        original = vc.CallError("PortAudioError", "open: original device error", 502)
        with patch.dict(sys.modules, {"websockets":transport}), patch.object(vc, "read_key", return_value="test-key"), \
             patch.object(self.backend, "handshake", new=AsyncMock()), \
             patch.object(self.backend.audio, "start", new=AsyncMock(side_effect=original)), \
             patch.object(self.backend, "close", new=AsyncMock(side_effect=RuntimeError("cleanup"))), \
             redirect_stderr(io.StringIO()):
            with self.assertRaises(vc.CallError) as caught:
                await self.backend.start()
        self.assertIs(caught.exception, original)

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
