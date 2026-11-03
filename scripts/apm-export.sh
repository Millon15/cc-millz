#!/usr/bin/env bash
set -euo pipefail
script_dir="${BASH_SOURCE[0]%/*}"
exec bun "$script_dir/apm-export.ts" "$@"
