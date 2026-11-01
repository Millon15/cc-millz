import { atom, read, update } from "claude-code";
import type { EngineInterface as Engine, Register } from "claude-code";

import type {
  CallView,
  Line,
  LineWho,
  PaneKey,
  WaitEvent,
  WaitResponse,
} from "../types";

/**
 * One instance per Claude session; only the instance in the pane the daemon pinned acts.
 *
 * Daemon contract: `scripts/voice-call` HTTP over `~/.local/state/voice-call/voice.sock`.
 */

const PANE_ID = "voice-call";
const PANE_TITLE = "Voice call";
const HOST = "http://voice-call";
const MAX_LINES = 300;
const MAX_SUBMIT_BYTES = 8192;
const RETRY_MS = 2000;
const MAX_SEEN_SUBMITS = 200;
const MERGE_GAP_MS = 2500;
const STREAMED: ReadonlySet<LineWho> = new Set(["you", "voice"]);

type PinnedStatus = Partial<PaneKey> & { claude_session_id?: string };

const lines = atom(
  { plugin: "voice-call", key: "lines" } as const,
  [] as Line[],
  { shape: "lines-1" },
);
const call = atom(
  { plugin: "voice-call", key: "call" } as const,
  null as CallView | null,
  { shape: "call-1" },
);
const generation = atom(
  { plugin: "voice-call", key: "generation" } as const,
  0,
  { shape: "generation-1" },
);

const LABELS: Record<LineWho, { tag: string; color: string }> = {
  you: { tag: "you  ", color: "yellow" },
  voice: { tag: "voice", color: "cyan" },
  system: { tag: "  ·  ", color: "gray" },
  sent: { tag: "→ cc ", color: "green" },
  held: { tag: "⏸ held", color: "red" },
};

let pane: PaneKey | undefined;
let socketPath = "";
let isPinned = false;
let isBusy = false;
const seenSubmits = new Set<string>();

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    const started = await next(e);
    pane = await resolvePane($);
    if (!pane) return started;

    await $.command.register({
      name: "voice-call",
      description: "Voice call: status, setup, hangup",
    });
    void healHotkeyLink($);
    void runWaitLoop($, await claimGeneration($)).catch(() => undefined);

    return started;
  });

  on("turn.start", async ($, e, next) => {
    if (e.agentId === undefined) isBusy = true;

    return next(e);
  });

  on("turn.complete", async ($, e, next) => {
    if (e.agentId !== undefined) return next(e);

    isBusy = false;
    if (isPinned)
      void post($, "/turn", {
        ...paneBody(),
        turn_id: e.turnId,
        answer: e.answer,
        aborted: e.isAborted,
      });

    return next(e);
  });

  on("prompt.submit", async ($, e, next) => {
    if (isPinned && e.origin.kind === "composer")
      void post($, "/prompt", { ...paneBody(), text: e.text });

    return next(e);
  });

  on("command.run", { command: "voice-call" }, async ($, e) => ({
    text: await runCommand($, e.args.trim()),
  }));

  on("ui.render", { component: "Pane", requestId: PANE_ID }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e);
    const view = await read($, call);
    const room = Math.max(1, (e.viewport?.rows ?? 24) - 3);
    const shown = (await read($, lines)).slice(-room);

    return (
      <Box flexDirection="column">
        <Text bold color="cyan">
          {view ? `● ${view.state} · ${view.model}` : "○ not pinned"}
        </Text>
        {shown.length === 0 && (
          <Text dimColor>Speak; the transcript appears here.</Text>
        )}
        {shown.map((line) => (
          <Text color={LABELS[line.who].color}>
            {LABELS[line.who].tag} {line.text.trim()}
          </Text>
        ))}
      </Box>
    );
  });
};

async function resolvePane($: Engine): Promise<PaneKey | undefined> {
  if ((await $.env.get("AGTERM_ENABLED")) !== "1") return undefined;

  const session = await $.env.get("AGTERM_SESSION_ID");
  const side = await $.env.get("AGTERM_PANE");
  if (!session || (side !== "left" && side !== "right")) return undefined;

  socketPath = `${await $.env.get("HOME")}/.local/state/voice-call/voice.sock`;

  return {
    agterm_session: session,
    pane: side,
    pane_id: (await $.env.get("AGTERM_PANE_ID")) ?? "",
  };
}

/** The agterm hotkeys call ~/.local/bin/voice-call; repoint it at this version after a plugin update. */
async function healHotkeyLink($: Engine): Promise<void> {
  await $.process
    .run([`${$.plugin.root}/scripts/voice-call`, "install", "--link-only"])
    .catch(() => undefined);
}

async function claimGeneration($: Engine): Promise<number> {
  await update($, generation, (current) => current + 1);

  return read($, generation);
}

async function runWaitLoop($: Engine, mine: number): Promise<void> {
  let since = 0;
  let isConnected = false;
  while ((await read($, generation)) === mine) {
    if (!isConnected) isConnected = await announce($);
    const response = isConnected
      ? await request<WaitResponse>($, "GET", waitPath(since))
      : undefined;
    if (!response) {
      if (isPinned) await setCallState($, "disconnected");
      isConnected = false;
      since = 0;
      await $.clock.sleep(RETRY_MS);
      continue;
    }
    since = response.seq;
    for (const event of response.events) await handleEvent($, event);
  }
}

function waitPath(since: number): string {
  const key = paneOrThrow();

  return `/wait?agterm_session=${encodeURIComponent(key.agterm_session)}&pane=${key.pane}&since=${since}`;
}

async function announce($: Engine): Promise<boolean> {
  const registered = await post<{ pinned: boolean }>($, "/register", {
    ...paneBody(),
    pane_id: paneOrThrow().pane_id,
    claude_session_id: await $.session.id(),
    transcript_path: null,
    cwd: await $.session.cwd(),
    title: "",
  });
  if (!registered) return false;
  if (registered.pinned && !isPinned) await refreshPinnedFromStatus($);
  if (!registered.pinned && isPinned) await hidePinned($);

  return true;
}

async function refreshPinnedFromStatus($: Engine): Promise<void> {
  const status = await request<{ call: string; model: string }>(
    $,
    "GET",
    "/status",
  );
  if (status) await showPinned($, status.call, status.model);
}

async function handleEvent($: Engine, event: WaitEvent): Promise<void> {
  switch (event.kind) {
    case "pinned":
      return showPinned($, event.call, event.model);
    case "unpinned":
      return hidePinned($);
    case "line":
      return appendLine($, event.who, event.text, event.ts * 1000);
    case "call":
      return setCallState($, event.state);
    case "submit":
      return deliverSubmit($, event.id, event.text);
  }
}

async function setCallState($: Engine, state: string): Promise<void> {
  await update($, call, (view) => (view ? { ...view, state } : view));
}

async function showPinned(
  $: Engine,
  state: string,
  model: string,
): Promise<void> {
  isPinned = true;
  await update($, call, () => ({ state, model }));
  await $.ui.open({ id: PANE_ID, title: PANE_TITLE });
  await appendLine($, "system", "pinned: the voice follows this session");
}

async function hidePinned($: Engine): Promise<void> {
  isPinned = false;
  await update($, call, () => null);
  await $.ui.close({ id: PANE_ID });
}

async function appendLine(
  $: Engine,
  who: LineWho,
  text: string,
  ts: number = Date.now(),
): Promise<void> {
  await update($, lines, (list) => mergeOrAppend(list, { who, text, ts }));
}

/** Streamed transcripts arrive word by word with their own spacing, so adjacent chunks join raw. */
function mergeOrAppend(list: readonly Line[], line: Line): Line[] {
  const last = list.at(-1);
  if (!last || !canMerge(last, line)) return [...list, line].slice(-MAX_LINES);

  return [
    ...list.slice(0, -1),
    { ...last, text: last.text + line.text, ts: line.ts },
  ];
}

function canMerge(last: Line, line: Line): boolean {
  return (
    last.who === line.who &&
    STREAMED.has(line.who) &&
    line.ts - last.ts < MERGE_GAP_MS
  );
}

async function deliverSubmit(
  $: Engine,
  id: string,
  text: string,
): Promise<void> {
  if (seenSubmits.has(id)) return;
  rememberSubmit(id);

  const refusal = submitRefusal(text) ?? (await pinMovedRefusal($));
  if (refusal) return reportSubmit($, id, "refused", text, refusal);

  void $.prompt
    .submit({ text, asUser: true })
    .catch((error) => reportSubmit($, id, "refused", text, String(error)));
  await reportSubmit($, id, isBusy ? "queued" : "sent", text);
}

function rememberSubmit(id: string): void {
  seenSubmits.add(id);
  if (seenSubmits.size > MAX_SEEN_SUBMITS)
    seenSubmits.delete(seenSubmits.values().next().value as string);
}

async function pinMovedRefusal($: Engine): Promise<string | undefined> {
  const status = await request<{ pinned: PinnedStatus | null }>(
    $,
    "GET",
    "/status",
  );
  const key = paneOrThrow();
  const isHere =
    status?.pinned?.agterm_session === key.agterm_session &&
    status.pinned.pane === key.pane &&
    status.pinned.claude_session_id === (await $.session.id());

  return isHere ? undefined : "the pin moved to another session";
}

function submitRefusal(text: string): string | undefined {
  if (text.trim() === "") return "empty instruction";
  if (new TextEncoder().encode(text).length > MAX_SUBMIT_BYTES)
    return `over ${MAX_SUBMIT_BYTES} bytes`;
  if (!isPinned) return "this session is not pinned";

  return undefined;
}

async function reportSubmit(
  $: Engine,
  id: string,
  status: "sent" | "queued" | "refused",
  text: string,
  reason?: string,
): Promise<void> {
  await post($, "/submit-result", {
    id,
    status,
    ...(reason ? { reason } : {}),
  });
  await appendLine(
    $,
    status === "refused" ? "held" : "sent",
    reason ? `${text} (${reason})` : text,
  );
}

async function runCommand($: Engine, args: string): Promise<string> {
  if (args === "setup") return runSetup($);
  if (args === "hangup")
    return (await post($, "/hangup", {})) ? "Call ended." : daemonDown();

  return describeStatus($);
}

async function runSetup($: Engine): Promise<string> {
  const ran = await $.process.run(
    [`${$.plugin.root}/scripts/voice-call`, "install"],
    { timeoutMs: 60_000 },
  );

  return ran.exitCode === 0
    ? ran.stdout.trim() || "voice-call installed."
    : `setup failed: ${ran.stderr.trim()}`;
}

async function describeStatus($: Engine): Promise<string> {
  const status = await request<{
    call: string;
    backend: string;
    model: string;
    pinned: unknown;
  }>($, "GET", "/status");
  if (!status) return daemonDown();

  const where = isPinned
    ? "pinned to THIS session"
    : status.pinned
      ? "pinned elsewhere"
      : "not pinned";

  return `voice-call: ${status.call} · ${status.backend}/${status.model} · ${where}`;
}

function daemonDown(): string {
  return "voice-call daemon is not running: press ⌥⌘V in a Claude pane, or run `/voice-call setup` first.";
}

function paneOrThrow(): PaneKey {
  if (!pane)
    throw new Error(
      "voice-call: no agterm pane resolved; session.start must run first",
    );

  return pane;
}

function paneBody(): { agterm_session: string; pane: "left" | "right" } {
  const key = paneOrThrow();

  return { agterm_session: key.agterm_session, pane: key.pane };
}

async function post<T = { ok: boolean }>(
  $: Engine,
  path: string,
  body: object,
): Promise<T | undefined> {
  return request<T>($, "POST", path, body);
}

async function request<T>(
  $: Engine,
  method: string,
  path: string,
  body?: object,
): Promise<T | undefined> {
  try {
    const response = await $.http.fetch(`${HOST}${path}`, {
      method,
      socketPath,
      headers: { "content-type": "application/json" },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

    return response.ok ? (JSON.parse(response.text) as T) : undefined;
  } catch {
    return undefined;
  }
}
