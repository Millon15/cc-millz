#!/usr/bin/env bash
# Deterministic draft writer. fd 3 preserves candidate stdin across the Python heredoc.
set -euo pipefail
exec python3 - "$0" "$@" 3<&0 <<'PY'
import argparse, hashlib, json, os, pathlib, re, subprocess, sys

root = pathlib.Path(sys.argv[1]).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(root / 'scripts/lib'))
from sl_ledger import CARD_ID, Ledger, card_view, loads, now_iso, open_store

def validate(value, schema):
    kind = schema.get('type')
    types = {'object': dict, 'array': list, 'string': str, 'integer': int}
    if kind and (not isinstance(value, types[kind]) or kind == 'integer' and isinstance(value, bool)):
        raise ValueError('schema type')
    if 'enum' in schema and value not in schema['enum']:
        raise ValueError('schema enum')
    if kind == 'object':
        props = schema.get('properties', {})
        if any(k not in value for k in schema.get('required', [])):
            raise ValueError('schema required')
        if schema.get('additionalProperties') is False and set(value) - set(props):
            raise ValueError('schema properties')
        for k, v in value.items():
            if k in props: validate(v, props[k])
    if kind == 'array':
        if len(value) > schema.get('maxItems', len(value)): raise ValueError('schema size')
        for v in value: validate(v, schema['items'])
    if kind == 'string':
        if not value.strip() or len(value) < schema.get('minLength', 0) or len(value) > schema.get('maxLength', len(value)):
            raise ValueError('schema length')
        if any(ord(c) < 32 for c in value): raise ValueError('control character')
    if kind == 'integer' and value < schema.get('minimum', value): raise ValueError('schema minimum')

def redact(text):
    command = [str(root / 'scripts/sl-redact.sh')]
    checked = subprocess.run(command + ['--check'], input=text, text=True, capture_output=True, timeout=15)
    if checked.returncode not in (0, 1): raise ValueError('redactor check failed')
    cleaned = subprocess.run(command, input=text, text=True, capture_output=True, timeout=15, check=True)
    return cleaned.stdout.rstrip('\n'), checked.returncode == 1

def read_links(path, size):
    """C5 links.json, index -> link. A bad file costs only its links, never the job."""
    if not path: return {}
    try:
        links = loads(pathlib.Path(path).read_text())['links']
        return {l['index']: l for l in links if isinstance(l, dict) and type(l.get('index')) is int and 0 <= l['index'] < size}
    except (OSError, ValueError, KeyError, TypeError):
        print('session-learnings: links file ignored', file=sys.stderr)
        return {}

def link_target(ledger, link, lesson, reasons, project):
    """Safety gate first: a quarantined lesson never links, and a quarantine card is never a target."""
    if not link or reasons: return None
    target = link.get('target')
    if link.get('relation') not in ('same', 'refines', 'contradicts') or not isinstance(target, str) or not CARD_ID.fullmatch(target):
        return drop_link('malformed')
    if not ledger.known(target[4:]): return drop_link('unknown target')
    view = card_view(ledger.history(target[4:]))
    if view['quarantine_reasons'] or view['status'] in ('quarantine', 'rejected', 'deprecated'): return drop_link('untrusted target')
    if view['scope'] != lesson['scope'] or lesson['scope'] == 'project' and view['project'] != project:
        return drop_link('scope mismatch')
    return link['relation'], target[4:]

def drop_link(why):
    print('session-learnings: link dropped: ' + why, file=sys.stderr)
    return None

def record_sighting(ledger, fingerprint, session, project, prepared_item, ts, revision=None):
    lesson, _, excerpt, klass, reasons = prepared_item
    if any(e['event'] in ('seen', 'confirmed') and e['session'] == session for e in ledger.history(fingerprint)): return
    event = {'event': 'confirmed' if ledger.known(fingerprint) else 'seen', 'fingerprint': fingerprint,
             'session': session, 'project': project, 'ts': ts, 'lesson': lesson, 'excerpt': excerpt,
             'class': klass, 'reasons': reasons}
    if revision: event['proposed_revision'] = revision
    ledger.events.append(event)

def record_contradiction(ledger, target, fingerprint, session, ts):
    if any(e['event'] == 'contradicted' and e.get('target') == 'lsn-' + fingerprint for e in ledger.history(target)): return
    ledger.events.append({'event': 'contradicted', 'fingerprint': target, 'target': 'lsn-' + fingerprint,
                          'session': session, 'ts': ts})

parser = argparse.ArgumentParser()
parser.add_argument('--validate-only', action='store_true')
parser.add_argument('--store', default=os.environ.get('SESSION_LEARNINGS_HOME', os.path.expanduser('~/.claude/learnings')))
parser.add_argument('--session')
parser.add_argument('--project')
parser.add_argument('--digest')
parser.add_argument('--links')
args = parser.parse_args(sys.argv[2:])
try:
    with os.fdopen(3, encoding='utf-8') as source: raw = source.read(65537)
    if len(raw.encode()) > 65536: raise ValueError('oversize candidates')
    candidates = loads(raw)
    validate(candidates, loads((root / 'schema/candidates.schema.json').read_text()))
    if args.validate_only: sys.exit(0)
    if not args.session or not args.project or not args.digest: raise ValueError('missing metadata')
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,200}', args.session) or args.session in ('.', '..'):
        raise ValueError('invalid session')
    if not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,239}', args.project) or args.project in ('.', '..'):
        raise ValueError('invalid project')
    digest_path = pathlib.Path(args.digest)
    if digest_path.stat().st_size > 2 * 1024 * 1024: raise ValueError('oversize digest')
    evidence = {}
    for line in digest_path.read_text().splitlines():
        if not line.strip(): continue
        item = loads(line)
        if not isinstance(item, dict) or type(item.get('line')) is not int or not isinstance(item.get('text'), str):
            raise ValueError('invalid digest')
        evidence.setdefault(item['line'], []).append(item)
    prepared = []
    deny = re.compile(r'\b(?:rm|chmod\s+777)\b|--no-verify|(?:curl|wget).*\|\s*(?:ba)?sh\b|--insecure|\b(?:disable|bypass|skip)\b.{0,35}\b(?:tls|ssl|verif|permission|hook)|\b(?:edit|change|modify)\b.{0,35}\b(?:permission|hook)', re.I)
    for lesson in candidates['lessons']:
        lesson = dict(lesson)
        reasons = []
        for key in ('claim', 'trigger', 'proof'):
            lesson[key], hit = redact(lesson[key])
            if hit: reasons.append('secret')
        matches = evidence.get(lesson['evidence_line'], [])
        # A transcript line can contain several tool_result blocks. Ambiguity is quarantined.
        item = matches[0] if len(matches) == 1 else {}
        excerpt, hit = redact(item.get('text', ''))
        if hit: reasons.append('secret')
        if item.get('class') not in ('human', 'exec_ok'): reasons.append('untrusted_evidence')
        if deny.search(' '.join(lesson[k] for k in ('claim', 'trigger', 'proof'))): reasons.append('dangerous_instruction')
        if '[REDACTED' in json.dumps(lesson).upper() or '[REDACTED' in excerpt.upper(): reasons.append('secret')
        identity = [lesson['scope'], args.project if lesson['scope'] == 'project' else '', lesson['kind'],
                    ' '.join(lesson['trigger'].casefold().split()), ' '.join(lesson['claim'].casefold().split())]
        fingerprint = hashlib.sha256(json.dumps(identity, ensure_ascii=False).encode()).hexdigest()
        prepared.append((lesson, fingerprint, excerpt[:400], item.get('class', 'unknown'), sorted(set(reasons))))
    if not prepared: sys.exit(0)
except (OSError, ValueError, TypeError, subprocess.SubprocessError):
    print('session-learnings: invalid candidates, digest, or redaction; nothing written', file=sys.stderr)
    sys.exit(2)

links = read_links(args.links, len(prepared))
try:
    store = open_store(args.store)
    with Ledger(store) as ledger:
        now, affected = now_iso(), set()
        for index, item in enumerate(prepared):
            lesson, fingerprint, _, _, reasons = item
            linked = link_target(ledger, links.get(index), lesson, reasons, args.project)
            relation, target = linked or (None, None)
            if relation in ('same', 'refines'):
                record_sighting(ledger, target, args.session, args.project, item, now,
                                lesson['claim'] if relation == 'refines' else None)
                affected.add(target)
                continue
            record_sighting(ledger, fingerprint, args.session, args.project, item, now)
            affected.add(fingerprint)
            if relation == 'contradicts':
                record_contradiction(ledger, target, fingerprint, args.session, now)
                record_contradiction(ledger, fingerprint, target, args.session, now)
                affected.add(target)
        # Ledger is authoritative. A retry after a crash regenerates missing cards without recounting.
        ledger.save()
        ledger.render(affected)
except (OSError, ValueError, KeyError, TypeError):
    print('session-learnings: merge failed; retain job for retry', file=sys.stderr)
    sys.exit(1)
PY
