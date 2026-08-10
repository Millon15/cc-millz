#!/usr/bin/env bash
# Restores whatever statusLine config existed before this plugin took over.
set -eu

settings="$HOME/.claude/settings.json"
backup="$HOME/.claude/statusline-previous.json"
tmp="${settings}.statusline.tmp"

[ -f "$settings" ] || {
	printf 'statusline: no settings.json, nothing to undo\n'
	exit 0
}

if [ -f "$backup" ]; then
	jq --slurpfile prev "$backup" '.statusLine = $prev[0].statusLine' "$settings" >"$tmp"
	printf 'statusline: restored previous config from %s\n' "$backup"
else
	jq 'del(.statusLine)' "$settings" >"$tmp"
	printf 'statusline: statusLine removed\n'
fi

mv "$tmp" "$settings"
