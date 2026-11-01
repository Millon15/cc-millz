export type LineWho = "you" | "voice" | "system" | "sent" | "held";

export type Line = { who: LineWho; text: string; ts: number };

export type CallView = { state: string; model: string };

export type PaneKey = {
  agterm_session: string;
  pane: "left" | "right";
  pane_id: string;
};

export type WaitEvent =
  | { kind: "pinned"; call: string; model: string }
  | { kind: "unpinned" }
  | { kind: "line"; who: "you" | "voice" | "system"; text: string; ts: number }
  | { kind: "submit"; id: string; text: string }
  | { kind: "call"; state: string };

export type WaitResponse = { seq: number; events: WaitEvent[] };

declare module "claude-code" {
  interface PluginState {
    "voice-call": {
      lines: Shaped<Line[]>;
      call: Shaped<CallView | null>;
      generation: Shaped<number>;
    };
  }
}
