#!/usr/bin/env bash
# Emit idempotent application telemetry; only sl-ledger.sh events writes it.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import argparse, json, os, pathlib, re, shlex, subprocess, sys

SCRIPTS = pathlib.Path(sys.argv[1]).resolve().parent
ID = re.compile(r'lsn-[0-9a-f]{64}\Z')

def text_of(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return '\n'.join(v.get('text', '') for v in value if isinstance(v, dict) and v.get('type') == 'text')
    return ''

def signature(value):
    return ' '.join(text_of(value).casefold().split())

def is_recall(command):
    try:
        words = shlex.split(command)
    except (ValueError, TypeError):
        return False
    if not words:
        return False
    if pathlib.PurePath(words[0]).name == 'env':
        words.pop(0)
    while words and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0]):
        words.pop(0)
    if words and pathlib.PurePath(words[0]).name in ('bash', 'sh'):
        words.pop(0)
    # Require an invocation in command position: echoed examples and file reads do not count.
    return bool(words and pathlib.PurePath(words[0]).name == 'sl-recall.sh')

def recall_ids(content, cards):
    found = set()
    for line in text_of(content).splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get('status') != 'candidate' or row.get('unreviewed') is not True:
            continue
        card_id = row.get('id', '')
        if isinstance(card_id, str) and ID.fullmatch(card_id) and card_id in cards:
            found.add(card_id)
    return found

def load_cards(args):
    project = pathlib.Path(args.transcript).parent.name
    result = subprocess.run([str(SCRIPTS/'sl-ledger.sh'), 'list', '--store='+args.store,
                             '--project='+project], capture_output=True, text=True, check=True, timeout=30)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    return {r['id']: r for r in rows if r.get('status') != 'quarantine' and
            (r.get('scope') == 'global' or r.get('scope') == 'project' and r.get('project') == project)}

def transcript_rows(path):
    with open(path, encoding='utf-8') as stream:
        for number, line in enumerate(stream):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and not row.get('isSidechain') and not row.get('isMeta'):
                yield number, row

def observations(path, cards):
    tools, applications, executions = {}, {}, []
    skill_ids = {}
    for card_id, card in cards.items():
        if card.get('status') == 'stable' and card.get('skill'):
            skill_ids.setdefault(card['skill'], []).append(card_id)
    for number, row in transcript_rows(path):
        content = row.get('message', {}).get('content', [])
        if not isinstance(content, list):
            continue
        for index, block in enumerate(content):
            if not isinstance(block, dict):
                continue
            position = (number, index)
            if row.get('type') == 'assistant' and block.get('type') == 'tool_use':
                tools[block.get('id')] = block
                if block.get('name') == 'Skill':
                    for card_id in skill_ids.get(block.get('input', {}).get('skill'), []):
                        applications.setdefault(card_id, []).append(position)
            if row.get('type') != 'user' or block.get('type') != 'tool_result':
                continue
            use = tools.get(block.get('tool_use_id'), {})
            if use.get('name') != 'Bash':
                continue
            if is_recall(use.get('input', {}).get('command', '')):
                if not block.get('is_error'):
                    for card_id in recall_ids(block.get('content'), cards):
                        applications.setdefault(card_id, []).append(position)
                continue
            executions.append((position, bool(block.get('is_error')), signature(block.get('content'))))
    return applications, executions

def outcome(positions, executions):
    any_success = False
    for applied_at in positions:
        preceding = [sig for pos, failed, sig in executions if pos < applied_at and failed and sig]
        after = [(failed, sig) for pos, failed, sig in executions if pos > applied_at]
        if preceding and any(failed and sig == preceding[-1] for failed, sig in after):
            return 'applied_fail'
        any_success = any_success or any(not failed for failed, _ in after)
    return 'applied_ok' if any_success else None

def main(args):
    cards = load_cards(args)
    applications, executions = observations(args.transcript, cards)
    for card_id, positions in sorted(applications.items()):
        types = ['applied']
        result = outcome(positions, executions)
        if result:
            types.append(result)
        for kind in types:
            print(json.dumps({'type': kind, 'id': card_id, 'session': args.session}))

parser = argparse.ArgumentParser()
parser.add_argument('--store', default=os.environ.get('SESSION_LEARNINGS_HOME', os.path.expanduser('~/.claude/learnings')))
parser.add_argument('--session', required=True)
parser.add_argument('--transcript', required=True)
try:
    main(parser.parse_args(sys.argv[2:]))
except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
    print('session-learnings: application scan unavailable', file=sys.stderr)
    sys.exit(2)
PY
