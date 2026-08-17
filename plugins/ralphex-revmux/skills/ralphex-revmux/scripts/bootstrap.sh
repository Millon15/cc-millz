#!/usr/bin/env bash
#
# ralphex-revmux bootstrap — install the plugin's project layer into the current
# repo: .ralphex/scripts/{ralphex-revmux-review.sh,review-preflight.sh} (copies,
# so the repo runs without the plugin cache), .ralphex/prompts/{custom_review,
# custom_eval}.txt, and the config snippet appended to .ralphex/config once.
# Never overwrites an existing file; prints what it wrote.
#
# Usage: bootstrap.sh [--force]
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES="$HERE/../templates"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

place() { # $1=src $2=dst [$3=mode]
	if [[ -e "$2" && $FORCE -eq 0 ]]; then
		echo "keep    $2"
		return
	fi
	mkdir -p "$(dirname "$2")"
	cat "$1" >"$2"
	[[ -n "${3:-}" ]] && chmod "$3" "$2"
	echo "wrote   $2"
}

append_config_snippet() {
	mkdir -p .ralphex
	touch .ralphex/config
	if grep -qE '^external_review_tool[[:space:]]*=' .ralphex/config; then
		echo "keep    .ralphex/config (external_review_tool already set — merge by hand: $TEMPLATES/ralphex-config.snippet)"
		return
	fi
	cat "$TEMPLATES/ralphex-config.snippet" >>.ralphex/config
	echo "wrote   .ralphex/config (appended the ralphex-revmux snippet)"
}

ignore_revmux_tasks() {
	grep -qxF '.revmux/tasks' .gitignore 2>/dev/null && return 0
	echo '.revmux/tasks' >>.gitignore
	echo "wrote   .gitignore (+ .revmux/tasks)"
}

place "$HERE/ralphex-revmux-review.sh" .ralphex/scripts/ralphex-revmux-review.sh 755
place "$HERE/review-preflight.sh" .ralphex/scripts/review-preflight.sh 755
place "$TEMPLATES/custom_review.txt" .ralphex/prompts/custom_review.txt
place "$TEMPLATES/custom_eval.txt" .ralphex/prompts/custom_eval.txt
append_config_snippet
ignore_revmux_tasks
echo "next    .ralphex/scripts/review-preflight.sh   # then: ralphex --tasks-only <plan> && ralphex --external-only <plan>"
