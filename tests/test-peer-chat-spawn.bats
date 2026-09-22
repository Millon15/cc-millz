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
    unset PEER_CHAT_PEER_HARNESS PEER_CHAT_PEER_MODEL PEER_CHAT_PEER_ARGS
    unset PEER_CHAT_CODEX_ARGS PEER_CHAT_CODEX_COMMAND PEER_CHAT_CLAUDE_COMMAND
    stub codex
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
pane = args[args.index('--pane') + 1] if '--pane' in args else 'right'
if args[0] == 'tree':
    print(json.dumps({'sessions':[dict(id=os.environ['SID'], hasSplit=state['hasSplit'],
        split=state['split'], foreground=state['left'], splitForeground=state['right'])]}))
elif args[:2] == ['session', 'split']:
    state.update(hasSplit=True, split=True)
elif args[:2] == ['session', 'text']:
    if state['pending'] and not (root / 'hide-quit').exists():
        print('❯ ' + state['pending'])
    elif state[pane]:
        print('❯' if 'claude' in state[pane][0] else '› Ask Codex to do anything')
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
        if not (root / 'never-start').exists():
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

@test "spawn: default opens a missing split and explicitly selects gpt-6-astra" {
    set_state '.hasSplit=false | .split=false'
    run bash "$SPAWN"
    assert_status 0
    assert_contains "$output" '"state":"started"'
    assert_launch_arg codex
    assert_launch_arg --model
    assert_launch_arg gpt-6-astra
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
    assert_launch_arg 'shell_environment_policy.set.PEER_CHAT_NAME="codex gpt-6-astra"'
    assert_launch_arg 'shell_environment_policy.set.PEER_CHAT_CODEX_COMMAND="codex-wrapper"'
}

@test "spawn: Claude shorthand injects environment and loads the plugin when no user install exists" {
    run bash "$SPAWN" claude:fable
    assert_status 0
    assert_launch_arg env
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
}

@test "spawn: an existing other harness needs an explicit restart" {
    set_pair claude claude
    run bash "$SPAWN"
    assert_status 1
    assert_contains "$output" 'use --restart'
    [ ! -e "$TMP/typed.jsonl" ]
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
    PEER_CHAT_CODEX_COMMAND=peer-chat-nonexistent-test-binary run bash "$SPAWN"
    assert_status 3
    assert_contains "$output" 'not on PATH'
    [ ! -e "$TMP/calls.jsonl" ]
}

@test "spawn: failed startup returns a pane-specific read-back command" {
    touch "$TMP/never-start"
    run bash "$SPAWN"
    assert_status 1
    assert_contains "$output" 'codex did not appear'
    assert_contains "$output" "session text --pane right --target $SID"
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
    assert_explain_source "$output" peer_model default
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = gpt-6-astra ]
    [ "$(printf '%s' "$output" | jq -r '.values.start_timeout')" = 30 ]
    [ ! -e "$TMP/calls.jsonl" ]
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

@test "explain: Claude without an explicit model uses the Claude default" {
    run bash "$SPAWN" --harness claude --explain
    assert_status 0
    [ "$(printf '%s' "$output" | jq -r '.values.peer_model')" = null ]
}

@test "config: invalid harness, arguments, model and profile are rejected before terminal IO" {
    unset PEER_CHAT_START_TIMEOUT
    for config in '{"peer_harness":"other"}' '{"peer_args":"--verbose"}' \
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
{"peer_args":["--profile","spaces ' quotes $(touch injected) ; touch injected2"]}
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
        '.[0:2] == $expected[0].peer_args' "$TMP/executed.json" >/dev/null
}
