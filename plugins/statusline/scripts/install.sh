#!/usr/bin/env bash
# Points ~/.claude/settings.json at this plugin's statusline script.
#
# Runs on every SessionStart because CLAUDE_PLUGIN_ROOT carries the plugin
# VERSION — a bump moves the path and would otherwise leave settings.json
# pointing at a cache directory that no longer exists.
set -eu

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

say() {
	[ "$quiet" = "1" ] && return 0
	printf '%s\n' "$1"
}

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$plugin_root" ] || plugin_root=$(cd "$(dirname "$0")/.." && pwd)

script="$plugin_root/scripts/statusline.sh"
settings="$HOME/.claude/settings.json"
backup="$HOME/.claude/statusline-previous.json"
desired="bash \"$script\""

[ -f "$script" ] || {
	printf 'statusline: script missing at %s\n' "$script" >&2
	exit 1
}
chmod +x "$script" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || {
	printf 'statusline: jq is required\n' >&2
	exit 1
}

[ -f "$settings" ] || printf '{}\n' >"$settings"

current=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null || printf '')
[ "$current" = "$desired" ] && {
	say "statusline: already pointed at $script"
	exit 0
}

# Preserve whatever was there before we ever touched it, exactly once
[ -f "$backup" ] || [ -z "$current" ] || {
	jq '{statusLine: .statusLine}' "$settings" >"$backup" 2>/dev/null || true
	say "statusline: previous config saved to $backup"
}

tmp="${settings}.statusline.tmp"
jq --arg cmd "$desired" '.statusLine = {"type": "command", "command": $cmd}' "$settings" >"$tmp"
mv "$tmp" "$settings"
say "statusline: installed -> $script"
