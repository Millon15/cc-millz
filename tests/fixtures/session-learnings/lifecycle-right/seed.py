"""Build a small real ledger for lane-R integration tests (no model or live store)."""
import datetime, json, pathlib, sys

store = pathlib.Path(sys.argv[1]); store.mkdir(parents=True, exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc)
project = '-example-project'
definitions = [
    ('a', 'project', project, 'candidate', 'When verifying package downloads', 'Always verify checksums before installing the downloaded package.'),
    ('b', 'global', None, 'candidate', 'When retrying BSD sed', 'Pass an empty suffix after the in-place flag.'),
    ('c', 'project', '-another-project', 'candidate', 'When verifying package downloads', 'Use the other project procedure.'),
    ('d', 'project', project, 'draft', 'When handling draft data', 'This draft must never be recalled.'),
    ('e', 'project', project, 'quarantine', 'When handling quarantined data', 'This quarantine must never be recalled.'),
    ('f', 'project', project, 'stable', 'When clearing generated caches', 'Regenerate the project cache before testing.'),
    ('1', 'project', project, 'rejected', 'When handling rejected data', 'This archive must never be recalled.'),
]
events = []
for digit, scope, slug, status, trigger, claim in definitions:
    fingerprint = digit*64
    lesson = dict(op='add', scope=scope, kind='gotcha', trigger=trigger, claim=claim, evidence_line=1, proof='A human verified the result.')
    days = [1, 0] if status in ('candidate', 'stable', 'rejected') else [0]
    for i, days_ago in enumerate(days):
        events.append(dict(event='seen' if i == 0 else 'confirmed', fingerprint=fingerprint,
                           session='seed'+str(i), project=slug or project,
                           ts=(now-datetime.timedelta(days=days_ago)).isoformat().replace('+00:00','Z'),
                           lesson=lesson, excerpt='Verified result.', **{'class':'human'},
                           reasons=['untrusted_evidence'] if status == 'quarantine' else []))
    if status == 'stable':
        events.append(dict(event='promoted', fingerprint=fingerprint, ts=now.isoformat(),
                           skill='learned-cache', path='/example/project/.claude/skills/learned-cache/SKILL.md'))
    if status == 'rejected':
        events.append(dict(event='rejected', fingerprint=fingerprint, ts=now.isoformat(), note='Superseded.'))
(store/'ledger.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
