#!/usr/bin/env bash
# Tool-free, isolated extraction. The executable override is never shell-evaluated.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import argparse, json, os, pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve().parent.parent
def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError('duplicate JSON key')
        result[key] = value
    return result

parser = argparse.ArgumentParser()
parser.add_argument('--digest', required=True)
args = parser.parse_args(sys.argv[2:])
try:
    path = pathlib.Path(args.digest)
    if path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError('digest too large')
    digest = path.read_text(encoding='utf-8')
    rows = [json.loads(line) for line in digest.splitlines() if line.strip()]
    if not rows:
        print('{"lessons":[]}')
        sys.exit(0)
    if any(not isinstance(r, dict) or not isinstance(r.get('text'), str) for r in rows):
        raise ValueError('invalid digest')
    # Defense in depth for direct CLI callers. Scrub before anything reaches the model.
    redacted = subprocess.run([str(root / 'scripts/sl-redact.sh'), '--jsonl'], input=digest,
                              text=True, capture_output=True, timeout=15, check=True).stdout
    executable = shutil.which(os.environ.get('SESSION_LEARNINGS_EXTRACTOR', 'claude'))
    if not executable:
        raise ValueError('extractor unavailable')
    executable = str(pathlib.Path(executable).resolve())
    argv = [executable, '-p', '--model', os.environ.get('SESSION_LEARNINGS_MODEL', 'claude-haiku-5-5'),
            '--safe-mode', '--no-session-persistence', '--tools', '', '--output-format', 'json',
            '--json-schema', (root / 'schema/candidates.schema.json').read_text(),
            '--system-prompt', (root / 'prompts/extract.md').read_text()]
    env = dict(os.environ, CLAUDE_LEARN_SKIP='1')
    env.pop('CLAUDECODE', None)
    timeout = int(env.get('SESSION_LEARNINGS_TIMEOUT', '120'))
    if timeout < 1 or timeout > 3600:
        raise ValueError('invalid timeout')
    with tempfile.TemporaryDirectory(prefix='sl-extract-') as cwd:
        result = subprocess.run(argv, input=redacted, text=True, capture_output=True,
                                cwd=cwd, env=env, timeout=timeout, check=True)
    if len(result.stdout.encode()) > 65536:
        raise ValueError('result too large')
    # CLI JSON mode wrappers are accepted only when they contain structured_output.
    candidate = json.loads(result.stdout, object_pairs_hook=strict_object)
    if isinstance(candidate, dict) and 'structured_output' in candidate:
        if candidate.get('is_error') is True:
            raise ValueError('model error')
        candidate = candidate['structured_output']
    payload = json.dumps(candidate, ensure_ascii=False)
    subprocess.run([str(root / 'scripts/sl-merge.sh'), '--validate-only'], input=payload,
                   text=True, capture_output=True, timeout=15, check=True)
    print(payload)
except (OSError, ValueError, subprocess.SubprocessError):
    # No stderr/model output here: both can contain the sensitive source material.
    print('session-learnings: extraction failed; no candidates emitted', file=sys.stderr)
    sys.exit(3)
PY
