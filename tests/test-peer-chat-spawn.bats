#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    source "$REPO_ROOT/tests/helpers/common.bash"
    setup_tmp
    PLUGIN="$REPO_ROOT/plugins/peer-chat"
    SPAWN="$PLUGIN/scripts/peer-chat-spawn.sh"
    export SID="11111111-1111-1111-1111-111111111111" WID="window-1"
    export AGTERM_ENABLED=1 AGTERM_SESSION_ID="$SID" AGTERM_WINDOW_ID="$WID" AGTERM_PANE=left
    export PEER_CHAT_START_TIMEOUT=1 PEER_CHAT_QUIT_SETTLE=0.2
    export CLAUDE_CONFIG_DIR="$TMP/claude"
    export CODEX_HOME="$TMP/codex home"
    unset PEER_CHAT_CODEX_MODE PEER_CHAT_PEER_FALLBACK
    unset PEER_CHAT_PEER_HARNESS PEER_CHAT_PEER_MODEL PEER_CHAT_PEER_ARGS
    unset PEER_CHAT_CODEX_ARGS PEER_CHAT_CODEX_COMMAND PEER_CHAT_CLAUDE_COMMAND
    unset AGTERM_PANE_ID AGTERM_SOCKET
    stub codex 'printf "%s\n" "$*" >> "$TMP/daemon-calls.txt"'
    stub claude
    stub peer-chat.py
    stub_agtermctl
    cd "$TMP"
    set_pair claude ""
}

teardown() { teardown_tmp; }

set_pair() {
    jq -n --arg left "$1" --arg right "$2" \
        '{left:(if $left == "" then [] else [$left] end),
          right:(if $right == "" then [] else [$right] end),
          hasSplit:true,split:true,pending:""}' > "$TMP/tree.json"
}

set_state() {
    jq "$1" "$TMP/tree.json" > "$TMP/next.json"
    mv "$TMP/next.json" "$TMP/tree.json"
}

stub_agtermctl() {
    cat > "$STUB_BIN/agtermctl" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import sys

root = Path(os.environ['TMP'])
args = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
state = json.loads((root / 'tree.json').read_text())
surfaces = [{'kind': 'left', 'paneID': 'pane-left'}]
if state['hasSplit']:
    surfaces.append({'kind': 'right', 'paneID': 'pane-right'})
if args[:2] in (['session', 'text'], ['session', 'type']):
    assert '--pane' not in args
    token = args[args.index('--pane-id') + 1]
    pane = next((item['kind'] for item in surfaces if item['paneID'] == token), None)
    if pane is None:
        raise SystemExit(f'unknown pane id: {token}')
if args[0] == 'tree':
    print(json.dumps({'sessions':[dict(id=os.environ['SID'], hasSplit=state['hasSplit'],
        split=state['split'], foreground=state['left'], splitForeground=state['right'], surfaces=surfaces)]}))
elif args[:2] == ['session', 'split']:
    state.update(hasSplit=True, split=True)
elif args[:2] == ['session', 'text']:
    if state['pending'] and not (root / 'hide-quit').exists():
        print('❯ ' + state['pending'])
    elif state[pane]:
        if (root / 'text-fails').exists():
            raise SystemExit(9)
        claude = 'claude' in state[pane][0]
        if (root / 'working').exists():
            print('✻ Pouncing… (2m 54s · ↓ 11.8k tokens)' if claude else '• Working (14s • esc to interrupt)')
        print('❯' if claude else '› Ask Codex to do anything')
    else:
        print('%')
elif args[:2] == ['session', 'type']:
    body = sys.stdin.read()
    with (root / 'typed.jsonl').open('a') as log:
        log.write(json.dumps(dict(pane=pane, body=body)) + '\n')
    if body in ('/quit', '/exit'):
        state['pending'] = body
    elif body == '\n' and state['pending']:
        if not (root / 'never-quit').exists():
            state[pane], state['pending'] = [], ''
    else:
        argv = shlex.split(body)
        (root / 'launch.txt').write_text(body)
        (root / 'launch.json').write_text(json.dumps(argv))
        command_index = next(i for i in range(1, len(argv)) if '=' not in argv[i]) if argv[0] == 'env' else 0
        blocked = (root / 'never-start').read_text().strip() if (root / 'never-start').exists() else None
        if blocked is None or (blocked and blocked != argv[command_index]):
            state[pane] = [argv[command_index]]
elif args[:2] != ['session', 'focus']:
    raise SystemExit('unexpected command: ' + repr(args))
(root / 'tree.json').write_text(json.dumps(state))
PY
    chmod +x "$STUB_BIN/agtermctl"
}

assert_launch_arg() {
    jq -e --arg expected "$1" 'index($expected) != null' "$TMP/launch.json" >/dev/null
}

@test "spawn: routes through the supplied socket and passes the peer token to Codex" {
    export AGTERM_SOCKET="$TMP/Application Support/agterm.sock"
    run bash "$SPAWN" codex
    assert_status 0
    assert_launch_arg "AGTERM_SOCKET=$AGTERM_SOCKET"
    assert_launch_arg "AGTERM_PANE_ID=pane-right"
    jq -es --arg socket "$AGTERM_SOCKET" 'all(.[]; .[-2:] == ["--socket", $socket])' "$TMP/calls.jsonl"
}

@test "spawn: all harness pairings work from both caller panes" {
    for caller in claude codex; do
        for peer in claude codex; do
            for own in left right; do
                if [ "$own" = left ]; then
                    set_pair "$caller" ""
                    target=right
                else
                    set_pair "" "$caller"
                    target=left
                fi
                AGTERM_PANE="$own" run bash "$SPAWN" --harness "$peer" --model test-model
                assert_status 0
                [ "$(printf '%s' "$output" | jq -r '.pane')" = "$target" ]
                [ "$(jq -r --arg p "$target" '.[$p][0]' "$TMP/tree.json")" = "$peer" ]
                [ "$(jq -r --arg p "$own" '.[$p][0]' "$TMP/tree.json")" = "$caller" ]
                assert_launch_arg test-model
                assert_contains "$(tail -1 "$TMP/calls.jsonl")" "\"focus\", \"$own\""
            done
        done
    done
}

@test "spawn: default opens a missing split and leaves the model to the Codex config" {
    set_state '.hasSplit=false | .split=false'
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"started"'
    assert_launch_arg codex
    jq -e 'index("--model") == null' "$TMP/launch.json" >/dev/null
    assert_launch_arg --no-daemon
    jq -e 'index("--remote") == null' "$TMP/launch.json" >/dev/null
    [ ! -e "$TMP/daemon-calls.txt" ]
    assert_contains "$(cat "$TMP/calls.jsonl")" '"session", "split", "on"'
    assert_contains "$(cat "$TMP/calls.jsonl")" "\"--window\", \"$WID\""
}

@test "spawn: Codex receives peer identity and wrapper environment through config flags" {
    stub codex-wrapper
    PEER_CHAT_CODEX_COMMAND=codex-wrapper run bash "$SPAWN"
    assert_status 0
    assert_launch_arg codex-wrapper
    assert_launch_arg "shell_environment_policy.set.AGTERM_SESSION_ID=\"$SID\""
    assert_launch_arg "shell_environment_policy.set.AGTERM_WINDOW_ID=\"$WID\""
    assert_launch_arg 'shell_environment_policy.set.AGTERM_PANE="right"'
    assert_launch_arg 'shell_environment_policy.set.AGTERM_ENABLED="1"'
    assert_launch_arg 'shell_environment_policy.set.PEER_CHAT_NAME="codex"'
    assert_launch_arg 'shell_environment_policy.set.PEER_CHAT_CODEX_COMMAND="codex-wrapper"'
    assert_launch_arg --no-daemon
    [ ! -e "$TMP/daemon-calls.txt" ]
}

@test "spawn: Codex also gets the peer identity in its process env, which its hooks read" {
    run bash "$SPAWN"
    assert_status 0
    jq -e '.[0] == "env"' "$TMP/launch.json" >/dev/null
    assert_launch_arg PEER_CHAT_NAME=codex
    assert_launch_arg AGTERM_PANE=right
    jq -e 'index("PEER_CHAT_NAME=codex") < index("codex")' "$TMP/launch.json" >/dev/null
}

@test "spawn: starts the local daemon without applying pane overrides globally" {
    export PEER_CHAT_CODEX_MODE=daemon
    run bash "$SPAWN"
    assert_status 0
    [ "$(cat "$TMP/daemon-calls.txt")" = 'app-server daemon start' ]
    assert_launch_arg --remote
    assert_launch_arg "unix://$CODEX_HOME/app-server-control/app-server-control.sock"
    assert_launch_arg --cd
    assert_launch_arg "$(pwd -P)"
    jq -e 'index("--no-daemon") == null' "$TMP/launch.json" >/dev/null
}

@test "spawn: an explicit working directory survives daemon mode" {
    export PEER_CHAT_CODEX_MODE=daemon
    PEER_CHAT_PEER_ARGS='["--cd", "/tmp/peer project"]' run bash "$SPAWN"
    assert_status 0
    [ "$(jq '[.[] | select(. == "--cd")] | length' "$TMP/launch.json")" = 1 ]
    assert_launch_arg '/tmp/peer project'
}

@test "spawn: --no-daemon preserves embedded mode without starting the server" {
    export PEER_CHAT_CODEX_MODE=daemon
    PEER_CHAT_PEER_ARGS='["--no-daemon"]' run bash "$SPAWN"
    assert_status 0
    assert_launch_arg --no-daemon
    [ "$(jq '[.[] | select(. == "--no-daemon")] | length' "$TMP/launch.json")" = 1 ]
    assert_launch_arg 'shell_environment_policy.set.AGTERM_PANE="right"'
    jq -e 'index("--remote") == null' "$TMP/launch.json" >/dev/null
    [ ! -e "$TMP/daemon-calls.txt" ]
}

@test "spawn: daemon startup failure falls back once or fails before touching the peer" {
    export PEER_CHAT_CODEX_MODE=daemon
    stub codex 'echo "daemon unavailable" >&2; exit 1'
    run bash "$SPAWN" --no-fallback
    assert_status 1
    assert_contains "$output" 'Codex daemon startup failed: daemon unavailable'
    [ ! -e "$TMP/typed.jsonl" ]
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"fallback_from":"codex"'
    assert_launch_arg claude
}

@test "spawn: daemon startup timeout fails before replacing an existing peer" {
    export PEER_CHAT_CODEX_MODE=daemon
    stub codex 'exec sleep 3'
    set_pair claude codex
    run bash "$SPAWN" --restart --no-fallback
    assert_status 1
    assert_contains "$output" 'Codex daemon startup timed out'
    [ ! -e "$TMP/typed.jsonl" ]
}

@test "spawn: daemon mode refuses remote endpoints and ignored client options" {
    export PEER_CHAT_CODEX_MODE=daemon
    for argv in '["--remote=ws://example.invalid"]' '["--profile", "review"]' \
        '["-preview"]' '["--strict-config"]' '["--oss"]'; do
        PEER_CHAT_PEER_ARGS="$argv" run bash "$SPAWN"
        assert_status 2
        [ ! -e "$TMP/daemon-calls.txt" ]
        [ ! -e "$TMP/typed.jsonl" ]
    done
}

@test "spawn: Claude shorthand injects environment and loads the plugin when no user install exists" {
    run bash "$SPAWN" claude:fable
    assert_status 0
    assert_launch_arg env
    jq -e 'index("--no-daemon") == null' "$TMP/launch.json" >/dev/null
    assert_launch_arg "AGTERM_SESSION_ID=$SID"
    assert_launch_arg "AGTERM_WINDOW_ID=$WID"
    assert_launch_arg AGTERM_PANE=right
    assert_launch_arg "PEER_CHAT_NAME=claude fable"
    assert_launch_arg --plugin-dir
    assert_launch_arg "$PLUGIN"
    assert_launch_arg fable
}

@test "spawn: an installed Claude user plugin avoids a duplicate and warns on version mismatch" {
    mkdir -p "$CLAUDE_CONFIG_DIR/plugins" "$TMP/installed"
    jq -n --arg path "$TMP/installed" \
        '{plugins:{"peer-chat@cc-millz":[{scope:"user",version:"0.0.0",installPath:$path}]}}' \
        > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    run bash "$SPAWN" claude:opus
    assert_status 0
    assert_contains "$output" 'warning: Claude user peer-chat 0.0.0 differs'
    jq -e 'index("--plugin-dir") == null' "$TMP/launch.json" >/dev/null
}

@test "spawn: a missing cached user install still loads the caller plugin" {
    mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
    jq -n --arg path "$TMP/missing" \
        '{plugins:{"peer-chat@cc-millz":[{scope:"user",version:"0.0.0",installPath:$path}]}}' \
        > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    run bash "$SPAWN" claude:opus
    assert_status 0
    assert_launch_arg --plugin-dir
}

@test "spawn: a matching running harness is reused without pretending to change its model" {
    set_pair claude codex
    run bash "$SPAWN" --model another-model
    assert_status 0
    assert_contains "$output" '"state":"already"'
    assert_contains "$output" '"launched":false'
    [ ! -e "$TMP/typed.jsonl" ]
    [ ! -e "$TMP/daemon-calls.txt" ]
}

@test "spawn: a reused peer mid-turn reports working and warns that the send queues behind it" {
    set_pair claude codex
    touch "$TMP/working"
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"already"'
    assert_contains "$output" '"peer_turn":"working"'
    assert_contains "$output" "the right pane's codex is mid-turn; a send queues behind its current task; --restart replaces it"
    [ ! -e "$TMP/typed.jsonl" ]
}

@test "spawn: a reused idle peer reports idle without a warning, and a fresh start reports idle" {
    set_pair claude codex
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"peer_turn":"idle"'
    ! printf '%s' "$output" | grep -q 'mid-turn'
    set_pair claude ""
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"started"'
    assert_contains "$output" '"peer_turn":"idle"'
}

@test "spawn: an unreadable peer screen reports unknown and never fails a reuse or a fresh start" {
    touch "$TMP/text-fails"
    set_pair claude codex
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"already"'
    assert_contains "$output" '"peer_turn":"unknown"'
    set_pair claude ""
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"started"'
    assert_contains "$output" '"peer_turn":"unknown"'
    assert_contains "$(tail -1 "$TMP/calls.jsonl")" '"focus", "left"'
}

@test "spawn: a sibling paste script that fails to load reports unknown instead of a traceback" {
    mkdir -p "$TMP/plugin/scripts"
    cp "$SPAWN" "$TMP/plugin/scripts/peer-chat-spawn.sh"
    printf 'import re\nre.compile("(")\n' > "$TMP/plugin/scripts/peer-chat-paste.py"
    set_pair claude codex
    run bash "$TMP/plugin/scripts/peer-chat-spawn.sh"
    assert_status 0
    assert_contains "$output" '"peer_turn":"unknown"'
    ! printf '%s' "$output" | grep -q 'Traceback'
}

@test "spawn: a Claude peer mid-turn is read from its spinner line" {
    set_pair codex claude
    touch "$TMP/working"
    run bash "$SPAWN" claude:fable
    assert_status 0
    assert_contains "$output" '"peer_turn":"working"'
    assert_contains "$output" "the right pane's claude is mid-turn"
}

@test "spawn: an existing other harness needs an explicit restart when no fallback accepts it" {
    set_pair claude claude
    run bash "$SPAWN" --no-fallback
    assert_status 1
    assert_contains "$output" 'use --restart'
    [ ! -e "$TMP/typed.jsonl" ]
}

@test "spawn: a peer already running the fallback harness is accepted as the fallback" {
    set_pair claude claude
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"already"'
    assert_contains "$output" '"harness":"claude"'
    assert_contains "$output" '"fallback_from":"codex"'
    assert_contains "$output" 'falling back to claude'
    assert_contains "$output" '"requested_model":null'
    [ ! -e "$TMP/typed.jsonl" ]
}

@test "spawn: a missing codex executable falls back to Claude using its own model config" {
    PEER_CHAT_CODEX_COMMAND=peer-chat-nonexistent-test-binary run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"started"'
    assert_contains "$output" '"harness":"claude"'
    assert_contains "$output" '"requested_model":null'
    assert_contains "$output" '"fallback_from":"codex"'
    assert_launch_arg claude
    assert_launch_arg PEER_CHAT_NAME=claude
    jq -e 'index("--model") == null' "$TMP/launch.json" >/dev/null
}

@test "spawn: a codex that never appears falls back once, and the fallback itself never falls back" {
    printf 'codex' > "$TMP/never-start"
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" 'codex did not appear'
    assert_contains "$output" '"harness":"claude"'
    assert_contains "$output" '"fallback_from":"codex"'
    printf '' > "$TMP/never-start"
    rm -f "$TMP/launch.json"
    set_pair claude ""
    run bash "$SPAWN"
    assert_status 1
    assert_contains "$output" 'claude did not appear'
    [ "$(grep -c 'falling back' <<<"$output")" -eq 1 ]
}

@test "spawn: --fallback picks the harness and model, --no-fallback keeps the missing dependency error" {
    export PEER_CHAT_CODEX_COMMAND=peer-chat-nonexistent-test-binary
    run bash "$SPAWN" --fallback claude:opus
    assert_status 0
    assert_contains "$output" '"requested_model":"opus"'
    run bash "$SPAWN" --no-fallback
    assert_status 3
    assert_contains "$output" 'not on PATH'
    PEER_CHAT_PEER_FALLBACK=vim run bash "$SPAWN"
    assert_status 2
    assert_contains "$output" 'peer_fallback must be'
}

@test "spawn: a busy unknown program is refused before any typing" {
    set_pair claude vim
    run bash "$SPAWN" --restart
    assert_status 1
    assert_contains "$output" 'unknown program'
    [ ! -e "$TMP/typed.jsonl" ]
}

@test "spawn: unknown caller and missing caller identity fail before typing" {
    set_pair vim ""
    run bash "$SPAWN"
    assert_status 4
    [ ! -e "$TMP/typed.jsonl" ]
    AGTERM_PANE= run bash "$SPAWN"
    assert_status 4
    assert_contains "$output" 'AGTERM_PANE'
}

@test "spawn: outside agterm is refused" {
    AGTERM_ENABLED= run bash "$SPAWN"
    assert_status 4
    assert_contains "$output" 'not inside agterm'
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "spawn: an absent selected executable reports the missing dependency" {
    PEER_CHAT_CODEX_COMMAND=peer-chat-nonexistent-test-binary run bash "$SPAWN" --no-fallback
    assert_status 3
    assert_contains "$output" 'not on PATH'
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "spawn: failed startup returns a pane-specific read-back command" {
    touch "$TMP/never-start"
    run bash "$SPAWN"
    assert_status 1
    assert_contains "$output" 'codex did not appear'
    assert_contains "$output" "session text --pane-id pane-right --target $SID"
}

@test "restart: both harnesses quit with their own command before a separate Return" {
    for running in codex claude; do
        set_pair claude "$running"
        rm -f "$TMP/typed.jsonl"
        run bash "$SPAWN" --restart --harness "$running"
        assert_status 0
        assert_contains "$output" '"state":"restarted"'
        if [ "$running" = codex ]; then expected=/quit; else expected=/exit; fi
        [ "$(head -1 "$TMP/typed.jsonl" | jq -r .body)" = "$expected" ]
        [ "$(sed -n '2p' "$TMP/typed.jsonl" | jq -r '.body | @json')" = '"\n"' ]
        [ "$(wc -l < "$TMP/typed.jsonl" | tr -d ' ')" = 3 ]
    done
}

@test "restart: a right-side caller can replace a Claude peer with Codex on the left" {
    set_pair claude codex
    AGTERM_PANE=right run bash "$SPAWN" --restart
    assert_status 0
    [ "$(head -1 "$TMP/typed.jsonl" | jq -r .body)" = /exit ]
    assert_contains "$output" '"pane":"left"'
    assert_launch_arg 'shell_environment_policy.set.AGTERM_PANE="left"'
}

@test "restart: a visible quit command gets only Return before the launch" {
    set_pair claude codex
    set_state '.pending="/quit"'
    run bash "$SPAWN" --restart
    assert_status 0
    [ "$(head -1 "$TMP/typed.jsonl" | jq -r '.body | @json')" = '"\n"' ]
    [ "$(wc -l < "$TMP/typed.jsonl" | tr -d ' ')" = 2 ]
}

@test "restart: no Return is sent when the quit command is not visible" {
    set_pair claude codex
    touch "$TMP/hide-quit"
    run bash "$SPAWN" --restart
    assert_status 1
    assert_contains "$output" 'no Return sent'
    [ "$(wc -l < "$TMP/typed.jsonl" | tr -d ' ')" = 1 ]
    [ ! -e "$TMP/launch.json" ]
}

@test "restart: failure to exit does not type a launch line" {
    set_pair claude codex
    touch "$TMP/never-quit"
    run bash "$SPAWN" --restart
    assert_status 1
    assert_contains "$output" 'did not return to a shell'
    [ ! -e "$TMP/launch.json" ]
}

@test "restart: a bare peer shell is a normal start" {
    run bash "$SPAWN" --restart
    assert_status 0
    assert_contains "$output" '"state":"started"'
    [ "$(wc -l < "$TMP/typed.jsonl" | tr -d ' ')" = 1 ]
}

@test "explain: defaults have sources and do not contact agterm" {
    unset PEER_CHAT_START_TIMEOUT
    run bash "$SPAWN" --explain
    assert_status 0
    assert_explain_complete "$output"
    assert_explain_source "$output" peer_harness default
    assert_explain_source "$output" codex_mode default
    [ "$(printf '%s' "$output" | jq -r .values.codex_mode)" = embedded ]
    assert_explain_source "$output" peer_model default
    assert_explain_source "$output" peer_fallback default
    [ "$(printf '%s' "$output" | jq -r '.values.peer_fallback')" = claude ]
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = null ]
    [ "$(printf '%s' "$output" | jq -r '.values.start_timeout')" = 30 ]
    [ ! -e "$TMP/calls.jsonl" ]
    [ ! -e "$TMP/daemon-calls.txt" ]
}

@test "explain: CLI beats environment which beats the project profile" {
    make_git_repo "$TMP/repo"
    printf '{"peer_harness":"claude","peer_model":"opus","peer_args":["--verbose"]}\n' > "$TMP/repo/.peer-chat.json"
    cd "$TMP/repo"
    run bash "$SPAWN" --explain
    assert_status 0
    assert_explain_source "$output" peer_harness profile
    assert_explain_source "$output" peer_model profile
    PEER_CHAT_PEER_MODEL=fable run bash "$SPAWN" --explain
    assert_status 0
    assert_explain_source "$output" peer_model detected:env:PEER_CHAT_PEER_MODEL
    PEER_CHAT_PEER_MODEL=fable run bash "$SPAWN" --model custom-model --explain
    assert_status 0
    assert_explain_source "$output" peer_model detected:cli:peer_model
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = custom-model ]
}

@test "explain: an env harness preset beats a CLI harness and keeps its own model" {
    bats_require_minimum_version 1.5.0
    export PEER_CHAT_PEER_HARNESS=claude PEER_CHAT_PEER_MODEL=claude-fable-5-2
    for request in codex 'codex(gpt-5.6-sol)' 'claude(opus)'; do
        run --separate-stderr bash "$SPAWN" "$request" --explain
        assert_status 0
        [ "$(printf '%s' "$output" | jq -r '.values.peer_harness')" = claude ]
        [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = claude-fable-5-2 ]
        assert_explain_source "$output" peer_harness detected:env:PEER_CHAT_PEER_HARNESS
        assert_explain_source "$output" peer_model detected:env:PEER_CHAT_PEER_MODEL
        [[ "$stderr" == *"preset claude(claude-fable-5-2) overrides the requested $request"* ]]
    done
    run --separate-stderr bash "$SPAWN" claude --explain
    assert_status 0
    [ -z "$stderr" ]
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "explain: a model-less env preset takes a CLI model for its own harness only" {
    bats_require_minimum_version 1.5.0
    export PEER_CHAT_PEER_HARNESS=claude
    run --separate-stderr bash "$SPAWN" 'claude(opus)' --explain
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = opus ]
    assert_explain_source "$output" peer_model detected:cli:peer_model
    run --separate-stderr bash "$SPAWN" 'codex(gpt-5.6-sol)' --explain
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.values.peer_harness')" = claude ]
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = null ]
    [[ "$stderr" == *"overrides the requested codex(gpt-5.6-sol)"* ]]
}

@test "explain: a model never crosses to a harness the CLI or env picked" {
    make_git_repo "$TMP/repo"
    printf '{"peer_harness":"claude","peer_model":"opus"}\n' > "$TMP/repo/.peer-chat.json"
    cd "$TMP/repo"
    run bash "$SPAWN" codex --explain
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.values.peer_harness')" = codex ]
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = null ]
    assert_explain_source "$output" peer_model default
    PEER_CHAT_PEER_HARNESS=codex run bash "$SPAWN" --explain
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = null ]
}

@test "spawn: a Claude env preset launches Claude even when codex was requested" {
    export PEER_CHAT_PEER_HARNESS=claude PEER_CHAT_PEER_MODEL=claude-fable-5-2 PEER_CHAT_PEER_FALLBACK=none
    run bash "$SPAWN" codex
    assert_status 0
    assert_launch_arg claude
    assert_launch_arg claude-fable-5-2
    [ "$(jq 'index("codex")' "$TMP/launch.json")" = null ]
}

@test "explain: Claude without an explicit model uses the Claude default" {
    run bash "$SPAWN" --harness claude --explain
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = null ]
    [ "$(printf '%s' "$output" | jq -r '.values.peer_fallback')" = codex ]
}

@test "config: invalid harness, arguments, model and profile are rejected before terminal IO" {
    unset PEER_CHAT_START_TIMEOUT
    for config in '{"codex_mode":"other"}' '{"peer_harness":"other"}' '{"peer_args":"--verbose"}' \
        '{"peer_args":[null]}' '{"peer_args":["--model","wrong"]}' \
        '{"peer_model":""}' '{"start_timeout":0}' '[]' 'broken'; do
        printf '%s\n' "$config" > "$TMP/.peer-chat.json"
        run bash "$SPAWN"
        assert_status 2
        [ ! -e "$TMP/calls.jsonl" ]
    done
}

@test "config: shorthand conflicts and unknown CLI harness are usage errors" {
    run bash "$SPAWN" claude:opus --harness codex
    assert_status 2
    run bash "$SPAWN" --harness other
    assert_status 2
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "spawn: shell metacharacters in argv remain literal when the launch line is executed" {
    cat > "$TMP/.peer-chat.json" <<'JSON'
{"peer_args":["--no-daemon","--profile","spaces ' quotes $(touch injected) ; touch injected2"]}
JSON
    cat > "$STUB_BIN/codex" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['TMP'], 'executed.json').write_text(json.dumps(sys.argv[1:]))
PY
    chmod +x "$STUB_BIN/codex"
    run bash "$SPAWN"
    assert_status 0
    run bash "$TMP/launch.txt"
    assert_status 0
    [ ! -e "$TMP/injected" ]
    [ ! -e "$TMP/injected2" ]
    jq -e --slurpfile expected "$TMP/.peer-chat.json" \
        '.[0:3] == $expected[0].peer_args' "$TMP/executed.json" >/dev/null
}

@test "spawn: custom client arguments keep embedded mode by default" {
    PEER_CHAT_PEER_ARGS='["--profile", "review"]' run bash "$SPAWN"
    assert_status 0
    assert_launch_arg --profile
    assert_launch_arg review
    assert_launch_arg --no-daemon
    [ ! -e "$TMP/daemon-calls.txt" ]
}

@test "spawn: remote endpoints are refused in embedded mode before typing" {
    PEER_CHAT_PEER_ARGS='["--remote=ws://example.invalid"]' run bash "$SPAWN"
    assert_status 2
    [ ! -e "$TMP/typed.jsonl" ]
    [ ! -e "$TMP/daemon-calls.txt" ]
}

@test "explain: daemon mode can be selected by profile and overridden by environment" {
    printf '{"codex_mode":"daemon"}\n' > "$TMP/.peer-chat.json"
    run bash "$SPAWN" --explain
    assert_status 0
    assert_explain_source "$output" codex_mode profile
    [ "$(printf '%s' "$output" | jq -r .values.codex_mode)" = daemon ]
    PEER_CHAT_CODEX_MODE=embedded run bash "$SPAWN" --explain
    assert_status 0
    assert_explain_source "$output" codex_mode detected:env:PEER_CHAT_CODEX_MODE
    [ "$(printf '%s' "$output" | jq -r .values.codex_mode)" = embedded ]
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "spawn: parenthesised and colon peers pass the exact model and label to either harness" {
    for harness in claude codex; do
        for peer in "$harness(gpt-x)" "$harness:gpt-x"; do
            set_pair claude ""
            run bash "$SPAWN" "$peer"
            assert_status 0
            assert_contains "$output" '"requested_model":"gpt-x"'
            jq -e 'index("--model") as $i | $i != null and .[$i + 1] == "gpt-x"' "$TMP/launch.json" >/dev/null
            if [ "$harness" = claude ]; then
                assert_launch_arg 'PEER_CHAT_NAME=claude gpt-x'
            else
                assert_launch_arg 'shell_environment_policy.set.PEER_CHAT_NAME="codex gpt-x"'
            fi
        done
    done
}

@test "spawn: bare peers omit the model flag and use a bare label for either harness" {
    for harness in claude codex; do
        set_pair claude ""
        run bash "$SPAWN" "$harness"
        assert_status 0
        assert_contains "$output" '"requested_model":null'
        jq -e 'index("--model") == null' "$TMP/launch.json" >/dev/null
        if [ "$harness" = claude ]; then
            assert_launch_arg PEER_CHAT_NAME=claude
        else
            assert_launch_arg 'shell_environment_policy.set.PEER_CHAT_NAME="codex"'
        fi
    done
}

@test "spawn: a missing Claude falls back to Codex using its own model config" {
    set_pair codex ""
    PEER_CHAT_CLAUDE_COMMAND=peer-chat-nonexistent-test-binary run bash "$SPAWN" claude
    assert_status 0
    assert_contains "$output" '"harness":"codex"'
    assert_contains "$output" '"fallback_from":"claude"'
    assert_contains "$output" '"requested_model":null'
    assert_launch_arg 'shell_environment_policy.set.PEER_CHAT_NAME="codex"'
    jq -e 'index("--model") == null' "$TMP/launch.json" >/dev/null
}

@test "spawn: all fallback sources accept both model forms and preserve the id" {
    export PEER_CHAT_CODEX_COMMAND=peer-chat-nonexistent-test-binary
    for source in cli env profile; do
        for peer in 'claude(opus)' 'claude:opus'; do
            set_pair claude ""
            case "$source" in
                cli) run bash "$SPAWN" --fallback "$peer" ;;
                env) PEER_CHAT_PEER_FALLBACK="$peer" run bash "$SPAWN" ;;
                profile)
                    jq -n --arg peer "$peer" '{peer_fallback:$peer}' > "$TMP/.peer-chat.json"
                    run bash "$SPAWN"
                    ;;
            esac
            assert_status 0
            assert_contains "$output" '"requested_model":"opus"'
            assert_launch_arg 'PEER_CHAT_NAME=claude opus'
            jq -e 'index("--model") as $i | $i != null and .[$i + 1] == "opus"' "$TMP/launch.json" >/dev/null
        done
    done
}

assert_peer_forms() {
    assert_contains "$output" 'claude | codex | <h>:<model> | <h>(<model>)'
}

@test "config: malformed positional peers are usage errors before terminal IO" {
    for peer in '' 'codex()' 'codex(' 'codex(a)b' 'codex(a(b))' 'codex:a(b)' 'codex:' \
        'gemini(x)' 'codex:-bad' 'claude(-bad)' $'codex(a\tb)' $'claude:a\nb' \
        $'codex(a\177b)' $'claude(a\302\205b)'; do
        run bash "$SPAWN" "$peer"
        assert_status 2
        assert_contains "$output" 'usage:'
        assert_peer_forms
    done
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "config: every fallback source rejects malformed peers before terminal IO" {
    for source in cli env profile; do
        for peer in 'codex()' 'codex(' 'codex(a)b' 'codex:a(b)' 'codex:' 'gemini(x)' \
            'codex:-bad' 'claude(-bad)' $'codex(a\tb)' $'claude:a\nb' $'claude(a\177b)'; do
            case "$source" in
                cli) run bash "$SPAWN" --fallback "$peer" ;;
                env) PEER_CHAT_PEER_FALLBACK="$peer" run bash "$SPAWN" ;;
                profile)
                    jq -n --arg peer "$peer" '{peer_fallback:$peer}' > "$TMP/.peer-chat.json"
                    run bash "$SPAWN"
                    ;;
            esac
            assert_status 2
            assert_contains "$output" 'peer_fallback must be'
            assert_peer_forms
        done
    done
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "config: non-string and empty fallback profiles report the peer grammar" {
    for value in null 12 '[]' '{}' '""'; do
        printf '{"peer_fallback":%s}\n' "$value" > "$TMP/.peer-chat.json"
        run bash "$SPAWN" --explain
        assert_status 2
        assert_peer_forms
    done
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "config: both peer forms reject conflicting flags and accept a matching explicit model" {
    for peer in 'codex(x)' 'codex:x'; do
        run bash "$SPAWN" "$peer" --model y
        assert_status 2
        assert_contains "$output" 'positional peer conflicts with --model'
        run bash "$SPAWN" "$peer" --harness claude
        assert_status 2
        assert_contains "$output" 'positional peer conflicts with --harness'
        run bash "$SPAWN" "$peer" --model x --explain
        assert_status 0
        [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = x ]
    done
    [ ! -e "$TMP/calls.jsonl" ]
}


@test "explain: fallback precedence keeps the selected form and its source" {
    printf '{"peer_fallback":"claude(profile-id)"}\n' > "$TMP/.peer-chat.json"
    run bash "$SPAWN" --explain
    assert_status 0
    assert_explain_source "$output" peer_fallback profile
    [ "$(printf '%s' "$output" | jq -r '.values.peer_fallback')" = 'claude(profile-id)' ]
    PEER_CHAT_PEER_FALLBACK='claude(env-id)' run bash "$SPAWN" --explain
    assert_status 0
    assert_explain_source "$output" peer_fallback detected:env:PEER_CHAT_PEER_FALLBACK
    [ "$(printf '%s' "$output" | jq -r '.values.peer_fallback')" = 'claude(env-id)' ]
    PEER_CHAT_PEER_FALLBACK='claude(env-id)' run bash "$SPAWN" --fallback 'claude(cli-id)' --explain
    assert_status 0
    assert_explain_source "$output" peer_fallback detected:cli:peer_fallback
    [ "$(printf '%s' "$output" | jq -r '.values.peer_fallback')" = 'claude(cli-id)' ]
    PEER_CHAT_PEER_FALLBACK='claude(env-id)' run bash "$SPAWN" --no-fallback --explain
    assert_status 0
    assert_explain_source "$output" peer_fallback detected:cli:peer_fallback
    [ "$(printf '%s' "$output" | jq -r '.values.peer_fallback')" = none ]
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "topic grant: an embedded Codex launch gets --add-dir on the canonical default topic dir, created" {
    run bash "$SPAWN" --topic-dir tmp/peer-chat/demo
    assert_status 0
    topic="$(pwd -P)/tmp/peer-chat/demo"
    [ -d "$topic" ]
    [ "$(jq -r 'index("--add-dir") as $i | .[$i + 1]' "$TMP/launch.json")" = "$topic" ]
    [ "$(printf '%s' "$output" | jq -r '.topic_grant')" = "$topic" ]
}

@test "topic grant: a --state directory outside the repo is granted when it holds state.json" {
    mkdir -p "$TMP/elsewhere/topic"
    printf '{}' > "$TMP/elsewhere/topic/state.json"
    run bash "$SPAWN" --topic-dir "$TMP/elsewhere/topic"
    assert_status 0
    [ "$(jq -r 'index("--add-dir") as $i | .[$i + 1]' "$TMP/launch.json")" = "$(cd "$TMP/elsewhere/topic" && pwd -P)" ]
}

@test "topic grant: a restart of an embedded Codex peer carries the grant" {
    set_pair claude codex
    run bash "$SPAWN" --restart --topic-dir tmp/peer-chat/demo
    assert_status 0
    assert_contains "$output" '"state":"restarted"'
    assert_launch_arg "$(pwd -P)/tmp/peer-chat/demo"
}

@test "topic grant: daemon mode adds nothing and says so" {
    export PEER_CHAT_CODEX_MODE=daemon
    run bash "$SPAWN" --topic-dir tmp/peer-chat/demo
    assert_status 0
    assert_contains "$output" "no topic grant in daemon mode for $(pwd -P)/tmp/peer-chat/demo"
    assert_not_contains "$output" 'cannot write'
    jq -e 'index("--add-dir") == null' "$TMP/launch.json" >/dev/null
    [ "$(printf '%s' "$output" | tail -1 | jq -r '.topic_grant')" = null ]
}

@test "topic grant: a Claude peer gets no grant" {
    run bash "$SPAWN" claude --topic-dir tmp/peer-chat/demo
    assert_status 0
    jq -e 'index("--add-dir") == null' "$TMP/launch.json" >/dev/null
    [ "$(printf '%s' "$output" | jq -r '.topic_grant')" = null ]
}

@test "topic grant: a reused peer types nothing and reports that no grant was applied" {
    set_pair claude codex
    run bash "$SPAWN" --topic-dir tmp/peer-chat/demo
    assert_status 0
    assert_contains "$output" 'existing thread; no new topic grant applied'
    assert_contains "$output" '"state":"already"'
    [ "$(printf '%s' "$output" | tail -1 | jq -r '.topic_grant')" = null ]
    [ ! -e "$TMP/typed.jsonl" ]
}

@test "topic grant: symlinks and foreign directories are refused before any pane action" {
    mkdir -p "$TMP/outside" "$TMP/tmp/peer-chat"
    printf '{}' > "$TMP/outside/state.json"
    ln -s "$TMP/outside" "$TMP/tmp/peer-chat/linked"
    mkdir -p "$TMP/plain"
    mkdir -p "$TMP/fake"
    ln -s "$TMP/outside/state.json" "$TMP/fake/state.json"
    for dir in tmp/peer-chat/linked plain fake tmp/peer-chat/bad/slug; do
        run bash "$SPAWN" --topic-dir "$dir"
        assert_status 2
        assert_contains "$output" "--topic-dir $dir"
    done
    [ ! -e "$TMP/calls.jsonl" ]
    [ ! -e "$TMP/typed.jsonl" ]
}

@test "topic grant: a default topic path whose tmp/peer-chat is redirected is refused even with a state.json" {
    mkdir -p "$TMP/outside/demo" "$TMP/tmp"
    printf '{}' > "$TMP/outside/demo/state.json"
    ln -s "$TMP/outside" "$TMP/tmp/peer-chat"
    for dir in tmp/peer-chat/demo "$TMP/tmp/peer-chat/demo"; do
        run bash "$SPAWN" --topic-dir "$dir"
        assert_status 2
        assert_contains "$output" "--topic-dir $dir resolves outside <repo>/tmp/peer-chat"
    done
    run bash "$SPAWN" --topic-dir "$TMP/outside/demo"
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.topic_grant')" = "$(cd "$TMP/outside/demo" && pwd -P)" ]
}

@test "topic grant: an alias followed by .. grants the directory the ledger path resolves to" {
    mkdir -p "$TMP/external/sub" "$TMP/external/topic" "$TMP/local/topic"
    printf '{}' > "$TMP/external/topic/state.json"
    printf '{}' > "$TMP/local/topic/state.json"
    ln -s "$TMP/external/sub" "$TMP/local/alias"
    run bash "$SPAWN" --topic-dir "$TMP/local/alias/../topic"
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.topic_grant')" = "$(cd -P "$TMP/local/alias/../topic" && pwd -P)" ]
    [ "$(cd -P "$TMP/local/alias/../topic" && pwd -P)" = "$(cd "$TMP/external/topic" && pwd -P)" ]
}
