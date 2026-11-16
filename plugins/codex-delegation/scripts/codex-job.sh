#!/usr/bin/env bash
set -euo pipefail
script_dir="${BASH_SOURCE[0]%/*}"
exec node "$script_dir/codex-job.mjs" "$@"
