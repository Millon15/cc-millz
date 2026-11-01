# 📞 voice-call

    /plugin install voice-call@cc-millz

Talk with a third, full-duplex voice about ONE Claude Code session while you are on a call with a human peer. The voice summarizes each Claude turn aloud, answers your questions from the session's full transcript, and forwards your instructions to Claude. The raw Claude output stays on screen.

⚠️ **Requires** the [agterm](https://agterm.com/) terminal (macOS), headphones, [uv](https://docs.astral.sh/uv/) and an OpenAI API key. Outside agterm the mod does nothing.

## Core ideas

- **One pinned pane, chosen by a hotkey.** `⌥⌘V` in a Claude pane pins the voice to it; pressed in a Codex pane of a split, it pins the sibling Claude pane. It stays pinned while you browse other sessions, until you press `⌥⌘V` somewhere else.
- **Everything else stays silent.** Turns from unpinned sessions are never spoken, however many agents are running.
- **The voice has the whole session.** OpenAI GPT-Live delegates to a Responses model with four tools: `search_transcript`, `read_turn`, `session_overview` and `send_to_claude`. Ask "what was the second option?" and the voice answers it without bothering Claude.
- **Instructions go through Claude's own queue.** `send_to_claude` lands as `$.prompt.submit`. Claude queues it behind a running turn, and your unsent draft is left alone. A submit after the pin moved, or a replayed one, is refused.
- **Full duplex, with a kill switch.** Talking over the voice cuts it off. `⌥⌘.` stops it at once. `⌥⌘⇧V` hangs up. An idle call hangs up after 15 minutes, because GPT-Live bills every open second.
- **GPT-Live first, Realtime as fallback.** With `backend: auto`, a key that lacks the `api.responses.write` scope falls back to `gpt-realtime-2.1` for that call, and the transcript says so.

## Security

- Claude's output and the transcript are untrusted text the voice reads. A forward needs your own transcribed speech in the last 30 s, never starts with `/` or `!`, and reaches Claude framed as a voice-call message, so Claude's permission prompts still apply.
- The 30 s gate narrows prompt injection; it does not prove the instruction was yours. Every forward shows as `→ cc` in the side pane.
- A repository's `.voice-call.json` can change the backend, model and voice. The first line of each call names the profile in use.

## Components

| Component | What it does |
|-----------|-------------|
| mod `hooks/register.tsx` | Runs in every Claude session: registers the pane with the daemon, draws the **Voice call** side pane when pinned, forwards finished turns and typed prompts, and delivers `send_to_claude` |
| `scripts/voice-call` | The CLI and daemon: one per Mac, mic and speaker over GPT-Live or Realtime, HTTP over `~/.local/state/voice-call/voice.sock`, call logs in `~/.local/state/voice-call/calls/` |
| `scripts/keymap.conf.snippet` | The three agterm hotkeys, appended to `~/.config/agterm/keymap.conf` by `install` |
| `/voice-call` | Status; `/voice-call setup` runs `install`; `/voice-call hangup` ends the call |

## Setup

```bash
/voice-call setup                     # links ~/.local/bin/voice-call, adds the hotkeys, reloads the keymap
voice-call key import --from <file>   # reads OPENAI_API_KEY from an env file into Keychain (voice-call/openai)
voice-call key check                  # confirms a key is there, never prints it
```

`OPENAI_API_KEY` in the environment overrides the Keychain item. For GPT-Live the key needs the `api.responses.write` scope.

## Updating

Every Claude start repoints `~/.local/bin/voice-call` at the installed plugin version (`install --link-only`). A daemon that is already running keeps its old code: stop it with `pkill -f 'voice_call.py serve'` after an update, and the next `⌥⌘V` starts the new one.

## Tuning

`voice-call --explain` prints the resolved config. An optional committed `.voice-call.json` at a project root sets `backend` (`auto` · `gpt-live` · `realtime` · `fake`), `model`, `brain_model`, `voice` and `idle_hangup_min`.

---

Part of [cc-millz](../../README.md).
