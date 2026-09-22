#!/usr/bin/env bash
exec python3 - "$0" "$@" <<'PY'
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time


class Failure(Exception):
    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class Config:
    profile_file: str | None
    values: dict
    sources: dict


def arguments():
    parser = argparse.ArgumentParser(description='Start a peer in the other agterm pane.')
    parser.add_argument('peer', nargs='?', help='claude[:model] or codex[:model]')
    parser.add_argument('--harness', choices=('claude', 'codex'))
    parser.add_argument('--model')
    parser.add_argument('--restart', action='store_true')
    parser.add_argument('--explain', action='store_true')
    args = parser.parse_args(sys.argv[2:])
    if args.peer:
        harness, separator, model = args.peer.partition(':')
        if harness not in ('claude', 'codex') or (separator and not model):
            parser.error('peer must be claude[:model] or codex[:model]')
        if args.harness and args.harness != harness:
            parser.error('positional peer conflicts with --harness')
        if args.model and separator and args.model != model:
            parser.error('positional peer conflicts with --model')
        args.harness = harness
        args.model = args.model if args.model is not None else (model if separator else None)
    return args


def read_profile():
    probe = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    root = Path(probe.stdout.strip()) if probe.returncode == 0 else Path.cwd()
    path = root / '.peer-chat.json'
    if not path.exists():
        return None, {}
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            raise ValueError('expected an object')
        return str(path), data
    except (OSError, ValueError) as error:
        raise Failure(f'unparseable {path}: {error}', 2) from error


def resolve_value(profile, key, env, default, cli=None):
    if cli is not None:
        return cli, f'detected:cli:{key}'
    if os.environ.get(env):
        return os.environ[env], f'detected:env:{env}'
    if key in profile:
        return profile[key], 'profile'
    return default, 'default'


def resolve_config(args):
    path, profile = read_profile()
    values, sources = {}, {}
    specs = [('peer_harness', 'PEER_CHAT_PEER_HARNESS', 'codex', args.harness)]
    specs += [(f'{name}_command', f'PEER_CHAT_{name.upper()}_COMMAND', name, None)
              for name in ('claude', 'codex')]
    specs += [('peer_args', 'PEER_CHAT_PEER_ARGS', [], None),
              ('start_timeout', 'PEER_CHAT_START_TIMEOUT', 30, None)]
    for key, env, default, cli in specs:
        values[key], sources[key] = resolve_value(profile, key, env, default, cli)
    default_model = 'gpt-6-astra' if values['peer_harness'] == 'codex' else None
    values['peer_model'], sources['peer_model'] = resolve_value(
        profile, 'peer_model', 'PEER_CHAT_PEER_MODEL', default_model, args.model)
    if sources['peer_args'].startswith('detected:env:'):
        try:
            values['peer_args'] = json.loads(values['peer_args'])
        except ValueError as error:
            raise Failure('PEER_CHAT_PEER_ARGS must be a JSON string array', 2) from error
    validate_config(values)
    values['start_timeout'] = int(values['start_timeout'])
    return Config(path, values, sources)


def valid_text(value):
    return isinstance(value, str) and bool(value) and not any(ord(c) < 32 for c in value)


def validate_config(values):
    if values['peer_harness'] not in ('claude', 'codex'):
        raise Failure('peer_harness must be claude or codex', 2)
    model = values['peer_model']
    if model is not None and (not valid_text(model) or model.startswith('-')):
        raise Failure('peer_model must be a nonempty model name', 2)
    argv = values['peer_args']
    if not isinstance(argv, list) or not all(isinstance(v, str) and not any(ord(c) < 32 for c in v) for v in argv):
        raise Failure('peer_args must be an array of strings without control characters', 2)
    if any(v in ('--model', '-m') or v.startswith('--model=') for v in argv):
        raise Failure('set peer_model instead of passing --model in peer_args', 2)
    timeout = values['start_timeout']
    if isinstance(timeout, bool) or not str(timeout).isdigit() or int(timeout) < 1:
        raise Failure('start_timeout must be a positive whole number of seconds', 2)
    for harness in ('claude', 'codex'):
        command = values[f'{harness}_command']
        if not valid_text(command) or any(c.isspace() for c in command):
            raise Failure(f'{harness}_command must be one executable name or path', 2)
    if Path(values['claude_command']).name == Path(values['codex_command']).name:
        raise Failure('claude_command and codex_command must identify different executables', 2)


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


class Terminal:
    def __init__(self, config):
        self.config = config.values
        self.session = os.environ.get('AGTERM_SESSION_ID', '')
        self.window = os.environ.get('AGTERM_WINDOW_ID', '')
        self.own_pane = os.environ.get('AGTERM_PANE', '')
        if os.environ.get('AGTERM_ENABLED') != '1':
            raise Failure('not inside agterm (AGTERM_ENABLED unset)', 4)
        if not self.session or self.own_pane not in ('left', 'right'):
            raise Failure('AGTERM_SESSION_ID and AGTERM_PANE=left|right are required', 4)
        self.peer_pane = 'right' if self.own_pane == 'left' else 'left'

    def ctl(self, *args, text=None):
        argv = ['agtermctl', *args]
        if self.window:
            argv += ['--window', self.window]
        result = subprocess.run(argv, input=text, capture_output=True, text=True)
        if result.returncode:
            raise Failure(f'agtermctl {args[0]} failed: {result.stderr.strip()}')
        return result.stdout

    def node(self):
        nodes = [node for node in walk(json.loads(self.ctl('tree', '--json')))
                 if str(node.get('id', '')).lower() == self.session.lower()]
        if len(nodes) != 1:
            raise Failure(f'expected one agterm session {self.session}, found {len(nodes)}', 4)
        return nodes[0]

    def foreground(self, node, pane):
        return node.get('foreground' if pane == 'left' else 'splitForeground', [])

    def harness(self, node, pane):
        foreground = self.foreground(node, pane)
        if not isinstance(foreground, list):
            raise Failure(f'invalid foreground for {pane} pane', 4)
        matches = [name for name in ('claude', 'codex') if any(
            re.search(r'(?:^|[/\s])' + re.escape(Path(self.config[f'{name}_command']).name) + r'(?:$|\s)', str(part))
            for part in foreground)]
        if len(matches) > 1:
            raise Failure(f'ambiguous harness in {pane} pane', 4)
        return matches[0] if matches else None

    def validate_caller(self):
        node = self.node()
        if self.own_pane == 'right' and not node.get('hasSplit'):
            raise Failure('the caller right pane no longer exists', 4)
        if not self.harness(node, self.own_pane):
            raise Failure(f'the caller {self.own_pane} pane is not a known harness', 4)

    def text(self):
        return self.ctl('session', 'text', '--pane', self.peer_pane, '--target', self.session)

    def type(self, text):
        self.ctl('session', 'type', '--stdin', '--pane', self.peer_pane, '--target', self.session, text=text)

    def show_split(self):
        node = self.node()
        if not node.get('split'):
            self.ctl('session', 'split', 'on', '--target', self.session)

    def wait(self, predicate, timeout, failure):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        hint = f'agtermctl session text --pane {self.peer_pane} --target {self.session}'
        raise Failure(f'{failure}; read it with: {hint}')

    def require_shell(self):
        if self.foreground(self.node(), self.peer_pane):
            raise Failure(f'the {self.peer_pane} pane became busy; nothing launched')

    def quit(self, harness):
        command = '/quit' if harness == 'codex' else '/exit'
        pattern = r'(?m)^\s*[›»❯]\s*' + re.escape(command) + r'\s*$'
        visible = lambda: bool(re.search(pattern, self.text()))
        if not visible():
            self.type(command)
        self.wait(visible, float(os.environ.get('PEER_CHAT_QUIT_SETTLE', '3')),
                  f'{command} did not appear; no Return sent')
        if self.harness(self.node(), self.peer_pane) != harness:
            raise Failure('target harness changed before restart Return')
        self.type('\n')
        self.wait(lambda: not self.foreground(self.node(), self.peer_pane), self.config['start_timeout'],
                  f'the {self.peer_pane} pane did not return to a shell after {command}')


def claude_plugin_args(plugin_root):
    registry = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))) / 'plugins/installed_plugins.json'
    if not registry.exists():
        return ['--plugin-dir', str(plugin_root)]
    try:
        records = json.loads(registry.read_text()).get('plugins', {}).get('peer-chat@cc-millz', [])
        usable = [record for record in records if record.get('scope') == 'user'
                  and record.get('installPath') and Path(record['installPath']).is_dir()]
        if not usable:
            return ['--plugin-dir', str(plugin_root)]
        version = json.loads((plugin_root / '.claude-plugin/plugin.json').read_text())['version']
        if usable[0].get('version') != version:
            print(f"peer-chat-spawn: warning: Claude user peer-chat {usable[0].get('version')} differs from launcher {version}", file=sys.stderr)
        return []
    except (OSError, ValueError, TypeError, AttributeError) as error:
        raise Failure(f'cannot verify Claude peer-chat install: {error}', 2) from error


def launch_argv(config, terminal, plugin_root):
    values = config.values
    harness, model = values['peer_harness'], values['peer_model']
    context = {'AGTERM_ENABLED': '1', 'AGTERM_SESSION_ID': terminal.session, 'AGTERM_WINDOW_ID': terminal.window,
               'AGTERM_PANE': terminal.peer_pane,
               'PEER_CHAT_NAME': ' '.join(value for value in (harness, model) if value),
               'PEER_CHAT_CLAUDE_COMMAND': values['claude_command'],
               'PEER_CHAT_CODEX_COMMAND': values['codex_command']}
    argv = [values[f'{harness}_command'], *values['peer_args']]
    if model:
        argv += ['--model', model]
    if harness == 'claude':
        return ['env', *(f'{key}={value}' for key, value in context.items()), *argv, *claude_plugin_args(plugin_root)]
    for key, value in context.items():
        argv += ['-c', f'shell_environment_policy.set.{key}={json.dumps(value)}']
    return argv


def require_tools(config):
    for tool in ('agtermctl', 'peer-chat.py', config.values[f"{config.values['peer_harness']}_command"]):
        if not shutil.which(tool):
            raise Failure(f'{tool} not on PATH; run peer-chat-install.sh or install the selected harness', 3)


def spawn(config, args, plugin_root):
    require_tools(config)
    terminal = Terminal(config)
    terminal.validate_caller()
    node = terminal.node()
    running = terminal.harness(node, terminal.peer_pane)
    if terminal.foreground(node, terminal.peer_pane) and not running:
        raise Failure(f'the {terminal.peer_pane} pane is busy with an unknown program')
    wanted = config.values['peer_harness']
    if running and not args.restart:
        if running != wanted:
            raise Failure(f'the peer runs {running}; use --restart to replace it with {wanted}')
        terminal.show_split()
        return report('already', terminal, config, False)
    argv = launch_argv(config, terminal, plugin_root)
    terminal.show_split()
    if running:
        terminal.quit(running)
    terminal.wait(lambda: bool(terminal.text().strip()), 5, 'the peer shell drew no prompt')
    terminal.require_shell()
    terminal.type(shlex.join(argv) + '\n')
    terminal.wait(lambda: terminal.harness(terminal.node(), terminal.peer_pane) == wanted,
                  config.values['start_timeout'], f'{wanted} did not appear in the {terminal.peer_pane} pane')
    terminal.ctl('session', 'focus', terminal.own_pane, '--target', terminal.session)
    return report('restarted' if running else 'started', terminal, config, True)


def report(state, terminal, config, launched):
    return {'state': state, 'session': terminal.session, 'pane': terminal.peer_pane,
            'harness': config.values['peer_harness'], 'requested_model': config.values['peer_model'],
            'launched': launched}


def main():
    args = arguments()
    config = resolve_config(args)
    if args.explain:
        result = {'plugin': 'peer-chat', 'profile_file': config.profile_file,
                  'values': config.values, 'sources': config.sources}
    else:
        result = spawn(config, args, Path(sys.argv[1]).resolve().parent.parent)
    print(json.dumps(result, separators=(',', ':')))


try:
    main()
except Failure as error:
    print(f'peer-chat-spawn: {error}', file=sys.stderr)
    sys.exit(error.status)
except (OSError, ValueError) as error:
    print(f'peer-chat-spawn: {error}', file=sys.stderr)
    sys.exit(1)
PY
