#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
    printf 'idea-config: python3 is required\n' >&2
    exit 2
fi
script_dir="${BASH_SOURCE[0]%/*}"
if [[ "${script_dir}" == "${BASH_SOURCE[0]}" ]]; then
    script_dir=.
fi
exec python3 "${script_dir}/idea_config.py" "$@"
