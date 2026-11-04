#!/usr/bin/env bash
# Link exact text deterministically and ask a tool-free judge about non-exact neighbors.
set -euo pipefail
exec python3 - "$0" "$@" 3<&0 <<'PY'
import argparse, json, os, pathlib, re, shutil, subprocess, sys, tempfile

SCRIPTS = pathlib.Path(sys.argv[1]).resolve().parent
ROOT = SCRIPTS.parent

def normalize(lesson):
    return ' '.join((lesson['trigger'] + ' ' + lesson['claim']).casefold().split())

def grams(text):
    return {text[i:i+3] for i in range(max(0, len(text)-2))}

def similarity(left, right):
    a, b = grams(left), grams(right)
    return len(a & b) / len(a | b) if a | b else float(left == right)

def valid_candidates(raw):
    if len(raw.encode()) > 65536:
        raise ValueError('candidate size')
    subprocess.run([str(SCRIPTS/'sl-merge.sh'), '--validate-only'], input=raw,
                   text=True, capture_output=True, check=True, timeout=15)
    return json.loads(raw)['lessons']

def load_cards(args):
    result = subprocess.run([str(SCRIPTS/'sl-ledger.sh'), 'list', '--store='+args.store,
                             '--project='+args.project, '--status=draft,candidate,stable'],
                            text=True, capture_output=True, check=True, timeout=30)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    return [r for r in rows if r.get('status') in ('draft', 'candidate', 'stable') and
            (r.get('scope') == 'global' or r.get('scope') == 'project' and r.get('project') == args.project)]

def find_neighbors(lessons, cards):
    links, pending = [], []
    for index, lesson in enumerate(lessons):
        text = normalize(lesson)
        ranked = [(similarity(text, normalize(c)), c) for c in cards if c['scope'] == lesson['scope']]
        ranked.sort(key=lambda pair: (-pair[0], pair[1]['id']))
        exact = next((c for _, c in ranked if normalize(c) == text), None)
        if exact:
            links.append({'index': index, 'relation': 'same', 'target': exact['id'], 'similarity': 1.0, 'by': 'exact'})
            continue
        options = [dict(id=c['id'], kind=c['kind'], trigger=c['trigger'], claim=c['claim'], similarity=score)
                   for score, c in ranked[:5] if score >= 0.35]
        if options:
            pending.append(dict(index=index, kind=lesson['kind'], trigger=lesson['trigger'], claim=lesson['claim'], options=options))
    return links, pending

def strict_object(pairs):
    value = {}
    for k, v in pairs:
        if k in value:
            raise ValueError('duplicate key')
        value[k] = v
    return value

def judge(pending):
    executable = shutil.which(os.environ.get('SESSION_LEARNINGS_EXTRACTOR', 'claude'))
    if not executable:
        return []
    payload = json.dumps({'candidates': pending}, ensure_ascii=False)
    clean = subprocess.run([str(SCRIPTS/'sl-redact.sh'), '--jsonl'], input=payload,
                           text=True, capture_output=True, check=True, timeout=15).stdout
    argv = [str(pathlib.Path(executable).resolve()), '-p', '--model', os.environ.get('SESSION_LEARNINGS_MODEL', 'claude-haiku-5-5'),
            '--safe-mode', '--no-session-persistence', '--tools', '', '--output-format', 'json',
            '--json-schema', (ROOT/'schema/judge.schema.json').read_text(),
            '--system-prompt', (ROOT/'prompts/judge.md').read_text()]
    env = dict(os.environ, CLAUDE_LEARN_SKIP='1')
    env.pop('CLAUDECODE', None)
    timeout = int(env.get('SESSION_LEARNINGS_TIMEOUT', '120'))
    if not 1 <= timeout <= 3600:
        return []
    with tempfile.TemporaryDirectory(prefix='sl-judge-') as cwd:
        result = subprocess.run(argv, input=clean, text=True, capture_output=True, check=True, cwd=cwd, env=env, timeout=timeout)
    if len(result.stdout.encode()) > 65536:
        return []
    value = json.loads(result.stdout, object_pairs_hook=strict_object)
    if isinstance(value, dict) and 'structured_output' in value:
        if value.get('is_error') is True:
            return []
        value = value['structured_output']
    return checked_decisions(value, pending)

def checked_decisions(value, pending):
    if not isinstance(value, dict) or set(value) != {'links'} or not isinstance(value['links'], list) or len(value['links']) > 5:
        return []
    offered = {p['index']: {c['id']: c['similarity'] for c in p['options']} for p in pending}
    links, seen = [], set()
    for link in value['links']:
        if not isinstance(link, dict) or set(link) != {'index', 'relation', 'target'}:
            return []
        index, relation, target = link['index'], link['relation'], link['target']
        if type(index) is not int or index in seen or index not in offered or not isinstance(target, str):
            return []
        if target not in offered[index] or relation not in ('same', 'refines', 'contradicts', 'different'):
            return []
        seen.add(index)
        if relation != 'different':
            links.append(dict(index=index, relation=relation, target=target, similarity=offered[index][target], by='judge'))
    return links

parser = argparse.ArgumentParser()
parser.add_argument('--store', default=os.environ.get('SESSION_LEARNINGS_HOME', os.path.expanduser('~/.claude/learnings')))
parser.add_argument('--project', required=True)
args = parser.parse_args(sys.argv[2:])
try:
    with os.fdopen(3, encoding='utf-8') as source:
        lessons = valid_candidates(source.read(65537))
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
    print('session-learnings: invalid dedup candidates', file=sys.stderr)
    sys.exit(2)
links = []
try:
    links, pending = find_neighbors(lessons, load_cards(args))
    if pending:
        links += judge(pending)
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
    print('session-learnings: dedup unavailable; keeping unlinked lessons', file=sys.stderr)
print(json.dumps({'links': sorted(links, key=lambda link: link['index'])}, ensure_ascii=False))
PY
