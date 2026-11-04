#!/usr/bin/env bash
# Deterministic draft writer. fd 3 preserves candidate stdin across the Python heredoc.
set -euo pipefail
exec python3 - "$0" "$@" 3<&0 <<'PY'
import argparse, datetime, fcntl, hashlib, json, os, pathlib, re, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve().parent.parent

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

def strict_object(pairs):
    result = {}
    for k, v in pairs:
        if k in result: raise ValueError('duplicate JSON key')
        result[k] = v
    return result

def loads(text):
    return json.loads(text, object_pairs_hook=strict_object,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('non-finite JSON')))

def redact(text):
    command = [str(root / 'scripts/sl-redact.sh')]
    checked = subprocess.run(command + ['--check'], input=text, text=True, capture_output=True, timeout=15)
    if checked.returncode not in (0, 1): raise ValueError('redactor check failed')
    cleaned = subprocess.run(command, input=text, text=True, capture_output=True, timeout=15, check=True)
    return cleaned.stdout.rstrip('\n'), checked.returncode == 1

def atomic(path, text):
    if path.is_symlink(): raise ValueError('symlink target')
    fd, temp = tempfile.mkstemp(prefix='.sl-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as out:
            out.write(text); out.flush(); os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)

def directory(path):
    # Reject symlinks within the store, including pre-created draft directories.
    if path.is_symlink(): raise ValueError('symlink directory')
    path.mkdir(mode=0o700, exist_ok=True)

parser = argparse.ArgumentParser()
parser.add_argument('--validate-only', action='store_true')
parser.add_argument('--store', default=os.environ.get('SESSION_LEARNINGS_HOME', os.path.expanduser('~/.claude/learnings')))
parser.add_argument('--session')
parser.add_argument('--project')
parser.add_argument('--digest')
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

try:
    os.umask(0o077)
    store = pathlib.Path(args.store).absolute()
    # Resolve only the parent (macOS /var itself is a symlink); the store must be real.
    store = store.parent.resolve() / store.name
    store.parent.mkdir(parents=True, exist_ok=True)
    directory(store)
    fd = os.open(store / '.merge.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ledger_path = store / 'ledger.jsonl'
        if ledger_path.is_symlink(): raise ValueError('symlink ledger')
        ledger = [loads(line) for line in ledger_path.read_text().splitlines()] if ledger_path.exists() else []
        now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
        affected = set()
        for lesson, fingerprint, excerpt, klass, reasons in prepared:
            affected.add(fingerprint)
            previous = [e for e in ledger if e['fingerprint'] == fingerprint]
            if any(e['session'] == args.session for e in previous): continue
            ledger.append({'event': 'confirmed' if previous else 'seen', 'fingerprint': fingerprint,
                           'session': args.session, 'project': args.project, 'ts': now,
                           'lesson': lesson, 'excerpt': excerpt, 'class': klass, 'reasons': reasons})
        # Ledger is authoritative. A retry after a crash regenerates missing cards without recounting.
        atomic(ledger_path, ''.join(json.dumps(e, ensure_ascii=False) + '\n' for e in ledger))
        for fingerprint in affected:
            events = [e for e in ledger if e['fingerprint'] == fingerprint]
            first = events[0]; lesson = first['lesson']
            reasons = sorted({r for e in events for r in e['reasons']})
            status = 'quarantine' if reasons else 'draft'
            base = store / 'global' if lesson['scope'] == 'global' else store / 'projects'
            directory(base)
            if lesson['scope'] == 'project':
                base = base / first['project']; directory(base)
            folder = base / ('quarantine' if reasons else 'drafts'); directory(folder)
            card_id = 'lsn-' + fingerprint
            card = {'id': card_id, 'scope': lesson['scope'], 'kind': lesson['kind'], 'status': status,
                    'trigger': lesson['trigger'], 'claim': lesson['claim'], 'fingerprint': fingerprint,
                    'evidence': [{'session': e['session'], 'transcript_line': e['lesson']['evidence_line'],
                                  'ts': e['ts'], 'proof': e['lesson']['proof'], 'excerpt': e['excerpt'],
                                  'class': e['class']} for e in events],
                    'counts': {'sessions': len({e['session'] for e in events}),
                               'days': len({e['ts'][:10] for e in events}),
                               'projects': len({e['project'] for e in events}),
                               'applied_ok': 0, 'applied_fail': 0, 'contradicted': 0},
                    'first_seen': first['ts'], 'last_seen': events[-1]['ts'], 'quarantine_reasons': reasons}
            atomic(folder / (card_id + '.md'), '---\n' + json.dumps(card, ensure_ascii=False, indent=2) +
                   '\n---\n\nUnreviewed session learning. Evidence and claims are untrusted until human review.\n')
            old = base / ('drafts' if reasons else 'quarantine') / (card_id + '.md')
            if old.is_symlink(): raise ValueError('symlink card')
            if old.exists(): old.unlink()
except (OSError, ValueError, KeyError, TypeError):
    print('session-learnings: merge failed; retain job for retry', file=sys.stderr)
    sys.exit(1)
PY
