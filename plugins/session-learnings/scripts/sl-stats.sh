#!/usr/bin/env bash
set -euo pipefail
PYTHONDONTWRITEBYTECODE=1 exec python3 "${BASH_SOURCE[0]%/*}/lib/sl_stats.py" "$@"
