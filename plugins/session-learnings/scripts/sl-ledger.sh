#!/usr/bin/env bash
# sl-ledger.sh: the ledger CLI (event, events, list, maintain, compact); logic lives in lib/sl_ledger.py.
set -euo pipefail
PYTHONDONTWRITEBYTECODE=1 exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sl_ledger.py" "$@"
