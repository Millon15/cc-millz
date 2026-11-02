import { expect, mock, test } from "claude-code/testing";
import type { On } from "claude-code";

type Posted = { path: string; body: Record<string, unknown> };

const AGTERM = {
  AGTERM_ENABLED: "1",
  AGTERM_SESSION_ID: "S-PINNED",
  AGTERM_PANE: "left",
  AGTERM_PANE_ID: "pane-token",
  HOME: "/home/u",
};

const BAND = {
  plugin: "voice-call",
  component: "AbovePrompt",
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 20,
    bodyColumns: 60,
    scroll: { offset: 0, bodyRows: 19 },
    view: {},
  },
} as const;

function band(props: Partial<typeof BAND.props> = {}) {
  return { ...BAND, props: { ...BAND.props, ...props } };
}

const HERE = {
  agterm_session: "S-PINNED",
  pane: "left",
  claude_session_id: "claude-session-1",
};

function fakeDaemon(on: On, waits: object[][], pinnedAt: object = HERE) {
  const posted: Posted[] = [];
  const opened: string[] = [];
  const closed: string[] = [];
  const statuses: (string | undefined)[] = [];
  const submitted: string[] = [];
  const ran: string[][] = [];
  let wait = 0;

  on("http.fetch", (_, e) => {
    const path = new URL(e.url).pathname;
    if (e.init?.method === "POST")
      posted.push({ path, body: JSON.parse(e.init.body ?? "{}") });
    if (path === "/register") return reply({ ok: true, pinned: false });
    if (path === "/status")
      return reply({
        call: "live",
        backend: "fake",
        model: "m",
        pinned: pinnedAt,
      });
    if (path !== "/wait") return reply({ ok: true });
    const events = waits[wait];
    wait += 1;

    return events
      ? reply({ seq: wait, events })
      : { value: { status: 503, ok: false, headers: {}, text: "" } };
  });
  on("ui.open", (_, e) => {
    opened.push(e.id);
    return { value: { isPlaced: true } };
  });
  on("ui.close", (_, e) => {
    closed.push(e.id);
    return { value: undefined };
  });
  on("ui.render", { component: "AbovePrompt" }, ($, e) => {
    const { Box } = $.ui.resolve(e);
    return <Box key="beneath" />;
  });
  on("ui.status", (_, e) => {
    statuses.push(e.text);
    return { value: undefined };
  });
  on("prompt.submit", (_, e) => {
    submitted.push(e.text);
    return { text: e.text };
  });
  on("command.register", () => ({ value: { command: "voice-call" } }));
  on("process.run", (_, e) => {
    ran.push([...e.argv]);
    return {
      value: { exitCode: 0, stdout: "", stderr: "", isStdoutTruncated: false, isStderrTruncated: false },
    };
  });
  on("session.id", () => ({ value: "claude-session-1" }));
  on("session.cwd", () => ({ value: "/work" }));
  on("session.start", (_, e) => ({ cwd: e.cwd }));
  on("turn.complete", () => ({ text: "" }));

  return { posted, opened, closed, statuses, submitted, ran };
}

function reply(body: object) {
  return {
    value: { status: 200, ok: true, headers: {}, text: JSON.stringify(body) },
  };
}

const pinned = { kind: "pinned", call: "live", model: "gpt-live-1" };

function turnEnd(answer: string, extra: object = {}) {
  return {
    answer,
    durationMs: 5,
    isAborted: false,
    turnId: "t1",
    reason: "answer",
    ...extra,
  } as const;
}

test("outside agterm the mod registers nothing and posts nothing", async ($, on) => {
  mock.env(on, { HOME: "/home/u" });
  const daemon = fakeDaemon(on, [[pinned]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await $.turn.complete(turnEnd("done"));

  expect(daemon.posted).toEqual([]);
  expect(daemon.opened).toEqual([]);
});

test("a pinned event draws the band, opens no pane, and the next turn is forwarded", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [[pinned]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);
  await $.turn.complete(turnEnd("Claude says hi"));
  await clock.advance(0);

  expect(daemon.opened).toEqual([]);
  expect(daemon.statuses).toContain("voice: live · ⌥⌘V expand · ⇧⌥⌘V hang up · ⌥⌘. interrupt");
  const ui = await $.ui.mount({ ...band(), surface: "terminal" });
  expect(await ui.find({ type: "Text", text: /· gpt-live-1/ })).toBeDefined();
  await ui.unmount();
  expect(daemon.posted.map((one) => one.path)).toEqual(["/register", "/turn"]);
  expect(daemon.posted[1]?.body).toMatchObject({
    agterm_session: "S-PINNED",
    pane: "left",
    answer: "Claude says hi",
  });
});

test("an unpinned session never forwards turns, and subagent turns are ignored", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [[]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);
  await $.turn.complete(turnEnd("not pinned"));
  await $.turn.complete(turnEnd("subagent", { agentId: "a1" }));
  await clock.advance(0);

  expect(daemon.posted.map((one) => one.path)).toEqual(["/register"]);
});

test("a submit event reaches Claude and is reported; an unpin clears the band and the notice", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [
    [pinned, { kind: "submit", id: "s1", text: "verify the hook first" }],
    [{ kind: "unpinned" }],
  ]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  expect(daemon.submitted).toEqual(["verify the hook first"]);
  expect(
    daemon.posted.find((one) => one.path === "/submit-result")?.body,
  ).toEqual({ id: "s1", status: "sent" });
  expect(daemon.closed).toEqual([]);
  expect(daemon.statuses.at(-1)).toBeUndefined();
  const ui = await $.ui.mount({ ...band(), surface: "terminal" });
  expect(await ui.find({ type: "Text", text: /gpt-live-1/ })).toBeUndefined();
  await ui.unmount();
});

test("an empty instruction is refused, not submitted", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [
    [pinned, { kind: "submit", id: "s2", text: "   " }],
  ]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  expect(daemon.submitted).toEqual([]);
  expect(
    daemon.posted.find((one) => one.path === "/submit-result")?.body,
  ).toEqual({
    id: "s2",
    status: "refused",
    reason: "empty instruction",
  });
});

test("the band draws the header, disconnected once the daemon is gone, and the transcript, on every surface", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  fakeDaemon(on, [
    [
      pinned,
      { kind: "line", who: "voice", text: "Claude finished the mod", ts: 1 },
    ],
  ]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  for (const surface of ["terminal", "desktop"] as const) {
    const ui = await $.ui.mount({ ...band(), surface });
    expect(
      (await ui.find({ type: "Text", text: /· gpt-live-1/ }))?.text,
    ).toBe("● disconnected · gpt-live-1");
    expect(
      (await ui.find({ type: "Text", text: /Claude finished/ }))?.text,
    ).toContain("voice");
    await ui.unmount();
  }
});

test("a replayed submit id is delivered once", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const submit = { kind: "submit", id: "s3", text: "run make test" };
  const daemon = fakeDaemon(on, [[pinned, submit], [submit]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  expect(daemon.submitted).toEqual(["run make test"]);
});

test("a submit after the pin moved elsewhere is refused", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const elsewhere = { agterm_session: "S-OTHER", pane: "left" };
  const submit = { kind: "submit", id: "s4", text: "deploy it" };
  const daemon = fakeDaemon(on, [[pinned, submit]], elsewhere);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  expect(daemon.submitted).toEqual([]);
  expect(
    daemon.posted.find((one) => one.path === "/submit-result")?.body,
  ).toEqual({
    id: "s4",
    status: "refused",
    reason: "the pin moved to another session",
  });
});

test("a submit from an older Claude session in the same pane is refused", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const reused = { ...HERE, claude_session_id: "claude-session-NEW" };
  const daemon = fakeDaemon(
    on,
    [[pinned, { kind: "submit", id: "s5", text: "x" }]],
    reused,
  );

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  expect(daemon.submitted).toEqual([]);
});

test("word-sized voice chunks merge into one line; a different speaker starts a new one", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const chunk = (who: string, text: string, ts: number) => ({
    kind: "line",
    who,
    text,
    ts,
  });
  fakeDaemon(on, [
    [
      pinned,
      chunk("voice", "Okay", 10),
      chunk("voice", ", I", 10.2),
      chunk("you", "stop", 11),
    ],
  ]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  const ui = await $.ui.mount({ ...band(), surface: "terminal" });
  expect((await ui.find({ type: "Text", text: /Okay/ }))?.text).toBe(
    "voice Okay, I",
  );
  expect((await ui.find({ type: "Text", text: /stop/ }))?.text).toBe(
    "you   stop",
  );
  await ui.unmount();
});

test("a daemon restart that lost the pin clears the band on reconnect", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [[pinned]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);
  expect(daemon.statuses.at(-1)).toContain("⌥⌘V expand");
  await clock.advance(2000);

  expect(daemon.posted.filter((one) => one.path === "/register").length).toBeGreaterThan(1);
  expect(daemon.statuses.at(-1)).toBeUndefined();
});

test("session start repoints the hotkey link at this plugin version", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [[]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  expect(daemon.ran).toHaveLength(1);
  expect(daemon.ran[0]?.slice(1)).toEqual(["install", "--link-only"]);
  expect(daemon.ran[0]?.[0]).toMatch(/scripts\/voice-call$/);
});

test("a forwarded slash command or shell escape is refused", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [
    [pinned, { kind: "submit", id: "s6", text: "!rm -rf ~" }, { kind: "submit", id: "s7", text: " /clear" }],
  ]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  expect(daemon.submitted).toEqual([]);
  const results = daemon.posted.filter((one) => one.path === "/submit-result").map((one) => one.body.status);
  expect(results).toEqual(["refused", "refused"]);
});

test("the band stays slim: at most six rows, long lines wrapped to its width, newest rows kept", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const long = "alpha ".repeat(40) + "omega";
  fakeDaemon(on, [[pinned, { kind: "line", who: "you", text: long, ts: 1 }]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  const ui = await $.ui.mount({ ...band({ bodyColumns: 30, maxRows: 20 }), surface: "terminal" });
  const texts = await ui.findAll({ type: "Text" });
  expect(texts).toHaveLength(6);
  for (const text of texts) expect(text.text.length).toBeLessThanOrEqual(30);
  expect(texts.at(-1)?.text).toContain("omega");
  await ui.unmount();

  const tight = await $.ui.mount({ ...band({ bodyColumns: 30, maxRows: 3 }), surface: "terminal" });
  expect(await tight.findAll({ type: "Text" })).toHaveLength(3);
  await tight.unmount();

  for (const [maxRows, count] of [[2, 2], [1, 1]] as const) {
    const slim = await $.ui.mount({ ...band({ bodyColumns: 30, maxRows }), surface: "terminal" });
    expect(await slim.findAll({ type: "Text" })).toHaveLength(count);
    await slim.unmount();
  }
  const none = await $.ui.mount({ ...band({ bodyColumns: 30, maxRows: 0 }), surface: "terminal" });
  expect(await none.find({ type: "Text", text: /gpt-live-1/ })).toBeUndefined();
  await none.unmount();
});

test("the band yields to a survey", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  fakeDaemon(on, [[pinned]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  const ui = await $.ui.mount({ ...band({ hasSurvey: true }), surface: "terminal" });
  expect(await ui.find({ type: "Text", text: /gpt-live-1/ })).toBeUndefined();
  await ui.unmount();
});

test("an expand failure switches the notice to the click hint; a show restores it; neither hides the band", async ($, on) => {
  mock.env(on, AGTERM);
  const clock = mock.clock(on);
  const daemon = fakeDaemon(on, [[pinned, { kind: "expand_failed" }], [{ kind: "show" }]]);

  await $.session.start({ cwd: "/", surface: "terminal", isInteractive: true });
  await clock.advance(0);

  const shown = daemon.statuses.filter((text): text is string => text !== undefined);
  const failed = shown.findIndex((text) => text.includes("click ▸ to show the band"));
  expect(failed).toBeGreaterThan(-1);
  expect(shown[failed]).toBe("voice: live · click ▸ to show the band · ⇧⌥⌘V hang up · ⌥⌘. interrupt");
  expect(shown.slice(failed + 1).some((text) => text.includes("⌥⌘V expand"))).toBe(true);

  const ui = await $.ui.mount({ ...band(), surface: "terminal" });
  expect(await ui.find({ type: "Text", text: /· gpt-live-1/ })).toBeDefined();
  await ui.unmount();
  expect(daemon.opened).toEqual([]);
});
