#!/usr/bin/env bash
#
# revmux-kit bootstrap — materialize the kit's project layer into ./.revmux/
# of the current repo: config (timeouts + default profile), profile.md
# template, and the four rosters (sol-panel, sol-final, fable-panel,
# fable-final). Never overwrites an existing file; prints what it wrote.
#
# Usage: bootstrap.sh [--force] [--target <dir>]     (target default: ./.revmux)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$HERE/../templates"
TARGET="./.revmux"
FORCE=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--force)
		FORCE=1
		shift
		;;
	--target)
		TARGET="$2"
		shift 2
		;;
	*)
		echo "bootstrap: unknown arg $1" >&2
		exit 2
		;;
	esac
done

place() { # $1=src $2=dst
	if [[ -e "$2" && $FORCE -eq 0 ]]; then
		echo "keep    $2"
		return
	fi
	mkdir -p "$(dirname "$2")"
	cat "$1" >"$2"
	echo "wrote   $2"
}

place "$TEMPLATES/config" "$TARGET/config"
place "$TEMPLATES/profile.md" "$TARGET/profile.md"
for p in "$TEMPLATES"/profiles/*.md; do
	place "$p" "$TARGET/prompts/profiles/$(basename "$p")"
done

command -v revmux >/dev/null 2>&1 || {
	echo "note: revmux not on PATH — brew install umputun/apps/revmux"
	exit 0
}
revmux config | jq -r '.profiles[] | select(.name | test("^(sol|fable)-")) | "profile \(.name): \([.roster[] | .name+"="+.executor+"/"+.model+":"+.effort] | join(", "))"'
