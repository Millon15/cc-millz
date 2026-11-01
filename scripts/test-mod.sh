#!/usr/bin/env bash
# Runs a mod plugin's native test (tests/test-<plugin>-mod.test.tsx) with `claude plugin test`,
# which only discovers tests inside the plugin folder: the plugin and its test are staged together.
set -euo pipefail

plugin="${1:?usage: scripts/test-mod.sh <plugin>}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
test_file="$repo/tests/test-$plugin-mod.test.tsx"
[ -f "$test_file" ] || { echo "no native mod test at $test_file" >&2; exit 2; }

stage="$(mktemp -d "${TMPDIR:-/tmp}/mod-test.$plugin.XXXXXX")"
command cp -R "$repo/plugins/$plugin" "$stage/$plugin"
command cp "$test_file" "$stage/$plugin/hooks/$plugin.test.tsx"

claude plugin validate "$repo/plugins/$plugin" >/dev/null
claude plugin test "$stage/$plugin"
