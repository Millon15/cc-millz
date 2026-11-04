#!/usr/bin/env bash
# Surface only relevant candidates; this read does not record a successful application.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import argparse, json, os, pathlib, re, subprocess, sys

SCRIPTS = pathlib.Path(sys.argv[1]).resolve().parent

def normalize(text):
    return ' '.join(text.casefold().split())

def grams(text):
    text = normalize(text)
    return {text[i:i+3] for i in range(max(0, len(text)-2))}

def relevance(query, card):
    text = card.get('trigger', '') + ' ' + card.get('claim', '')
    q, c = set(re.findall(r'\w+', normalize(query))), set(re.findall(r'\w+', normalize(text)))
    a, b = grams(query), grams(text)
    overlap = len(a & b) / len(a | b) if a | b else 0
    if q and not q & c and overlap < 0.2:
        return None
    return len(q & c) / max(1, len(q)) + overlap

def candidates(store, project):
    result = subprocess.run([str(SCRIPTS/'sl-ledger.sh'), 'list', '--store='+store,
                             '--project='+project, '--status=candidate'],
                            text=True, capture_output=True, check=True, timeout=30)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    return [r for r in rows if r.get('status') == 'candidate' and
            (r.get('scope') == 'global' or r.get('scope') == 'project' and r.get('project') == project)]

def render(card):
    return {'id': card['id'], 'status': 'candidate', 'unreviewed': True,
            'scope': card['scope'], 'trigger': card['trigger'], 'claim': card['claim'],
            'score': card['score'], 'flags': card.get('flags', [])}

def main(args):
    if not 1 <= args.limit <= 20:
        raise ValueError('limit must be 1..20')
    project = re.sub(r'[^A-Za-z0-9]', '-', str(pathlib.Path(args.project_dir).expanduser().resolve()))
    ranked = [(relevance(args.query, c), c) for c in candidates(args.store, project)]
    ranked = [(rank, c) for rank, c in ranked if rank is not None]
    ranked.sort(key=lambda pair: (-pair[0], -pair[1]['score'], pair[1]['id']))
    output = ''.join(json.dumps(render(c), ensure_ascii=False) + '\n' for _, c in ranked[:args.limit])
    clean = subprocess.run([str(SCRIPTS/'sl-redact.sh'), '--jsonl'], input=output,
                           text=True, capture_output=True, check=True, timeout=15)
    sys.stdout.write(clean.stdout)

parser = argparse.ArgumentParser()
parser.add_argument('--store', default=os.environ.get('SESSION_LEARNINGS_HOME', os.path.expanduser('~/.claude/learnings')))
parser.add_argument('--project-dir', required=True)
parser.add_argument('--query', default='')
parser.add_argument('--limit', type=int, default=5)
try:
    main(parser.parse_args(sys.argv[2:]))
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
    print('session-learnings: recall unavailable', file=sys.stderr)
    sys.exit(2)
PY
