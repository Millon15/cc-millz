#!/usr/bin/env bash
# Read skill usage counters without changing Claude's config.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse, json, os, pathlib, sys

def read_usage(path):
    try:
        config = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return []
    usage = config.get('skillUsage', {}) if isinstance(config, dict) else {}
    if not isinstance(usage, dict):
        return []
    return [valid_row(name, value) for name, value in sorted(usage.items())]

def valid_row(name, value):
    if not isinstance(value, dict) or not name:
        return None
    count, last = value.get('usageCount'), value.get('lastUsedAt')
    if type(count) is not int or type(last) is not int or min(count, last) < 0:
        return None
    return {'skill': name, 'usageCount': count, 'lastUsedAt': last}

parser = argparse.ArgumentParser()
parser.add_argument('--config', default=str(pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~'))) / '.claude.json'))
args = parser.parse_args()
for row in read_usage(pathlib.Path(args.config)):
    if row is not None:
        print(json.dumps(row, ensure_ascii=False))
PY
