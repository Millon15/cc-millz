#!/usr/bin/env bash
# sl-signal.sh: decide from a digest whether a session is worth an extractor call; prints a JSON verdict.
#
# Exit 0 = signal, 1 = no signal. A signal only nominates a session, it proves nothing:
# at least SESSION_LEARNINGS_MIN_HUMAN human turns, and either
#   - a Bash failure followed by a Bash success within the next 20 digest rows, or
#   - a human turn that reads like a correction.
set -euo pipefail

MIN_HUMAN="${SESSION_LEARNINGS_MIN_HUMAN:-3}"

usage() {
	echo "usage: sl-signal.sh <digest.jsonl>" >&2
	exit 64
}

main() {
	[ "$#" -eq 1 ] || usage
	[ -r "$1" ] || {
		echo "sl-signal: cannot read $1" >&2
		exit 66
	}
	local verdict
	verdict="$(jq -nc --argjson min "$MIN_HUMAN" -f <(signal_program) "$1")"
	printf '%s\n' "$verdict"
	jq -e '.signal' >/dev/null <<<"$verdict"
}

signal_program() {
	cat <<'JQ'
def correction:
  test("(?i)(\\b(no|wrong|not that|instead|doesn'?t work|still (fails|broken)|stop)\\b|нет|не так|неправильн|не работает)");

[inputs] as $rows
| ($rows | map(select(.class == "human")) | length) as $human
| ([ $rows | to_entries[] | select(.value.class == "exec_error") | .key ]) as $errors
| any($errors[]; . as $i | any($rows[$i + 1:$i + 21][]; .class == "exec_ok")) as $fix
| any($rows[]; .class == "human" and (.text | correction)) as $corrected
| {human: $human, fix_window: $fix, correction: $corrected, signal: ($human >= $min and ($fix or $corrected))}
JQ
}

main "$@"
