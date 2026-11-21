#!/usr/bin/env bash
# sl-retro.sh: find, render and coverage-gate past Claude and Codex sessions; logic lives in lib/sl_retro.py.
set -euo pipefail
PYTHONDONTWRITEBYTECODE=1 exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sl_retro.py" "$@"
