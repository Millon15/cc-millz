#!/usr/bin/env bash
# sl-digest.sh: turn a Claude Code transcript into the redacted digest JSONL the extractor reads.
#
# One object per kept event: {line, role, class, tool, text}.
# `class` is machine-derived from the transcript, never from the model:
#   human       user prompt typed by a person (origin.kind == "human"), minus peer-chat "Chat from " pastes
#   exec_ok     result of a Bash tool_use, is_error false or absent
#   exec_error  result of a Bash tool_use, is_error true
#   read        result of any other tool, or of a tool_use that cannot be linked
#   assistant   assistant prose
# Redaction runs on the full text BEFORE truncation.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEXT_LIMIT="${SESSION_LEARNINGS_TEXT_LIMIT:-500}"
BUDGET_BYTES="${SESSION_LEARNINGS_DIGEST_BUDGET:-300000}"

usage() {
	echo "usage: sl-digest.sh <transcript.jsonl>" >&2
	exit 64
}

main() {
	[ "$#" -eq 1 ] || usage
	[ -r "$1" ] || {
		echo "sl-digest: cannot read $1" >&2
		exit 66
	}
	classify_events "$1" | "$SCRIPTS_DIR/sl-redact.sh" --jsonl | truncate_text | fit_budget
}

classify_events() {
	jq -nRc -f <(classify_program) "$1"
}

truncate_text() {
	jq -c --argjson limit "$TEXT_LIMIT" '{line, role, class, tool, text: .text[0:$limit]}'
}

# Over budget, human and Bash rows win over prose and reads; within each group the newest rows stay.
fit_budget() {
	jq -nc --argjson budget "$BUDGET_BYTES" -f <(budget_program)
}

budget_program() {
	cat <<'JQ'
def size: tojson | utf8bytelength + 1;
def newest_within($limit):
  reverse
  | reduce .[] as $row ({rows: [], used: 0};
      if .used + ($row | size) <= $limit then .rows += [$row] | .used += ($row | size) else . end)
  | .rows;
def core: .class | IN("human", "exec_ok", "exec_error");

[inputs] as $rows
| if ($rows | map(size) | add // 0) <= $budget then $rows[]
  else
    ($rows | map(select(core)) | newest_within($budget)) as $kept
    | ($budget - ($kept | map(size) | add // 0)) as $left
    | ($kept + ($rows | map(select(core | not)) | newest_within($left))) | sort_by(.line)[]
  end
JQ
}

classify_program() {
	cat <<'JQ'
def text_of:
  if type == "string" then .
  elif type == "array" then [ .[] | select(type == "object" and .type == "text") | .text ] | join("\n")
  else "" end;

def invocation:
  (.input // {}) as $in
  | if .name == "Bash" then "$ " + ($in.command // "")
    else .name + " " + ($in.file_path // $in.url // $in.pattern // $in.path // "" | tostring) end;

def tool_row($line; $tools):
  ($tools[.tool_use_id] // null) as $use
  | ($use.name // null) as $name
  | {
      line: $line,
      role: "tool",
      class: (if $name == "Bash" then (if .is_error == true then "exec_error" else "exec_ok" end) else "read" end),
      tool: $name,
      text: ([($use | if . then invocation else empty end), (.content | text_of)] | join("\n"))
    };

[inputs]
| to_entries
| map({line: (.key + 1), e: (.value | fromjson? // null)})
| map(select(.e != null and .e.isSidechain != true and .e.isMeta != true))
| . as $rows
| ([ $rows[].e | select(.type == "assistant") | .message.content[]?
     | select(type == "object" and .type == "tool_use") | {key: .id, value: .} ] | from_entries) as $tools
| $rows[]
| .line as $line
| .e as $e
| if $e.type == "user" and ($e.origin.kind? == "human") then
    ($e.message.content | text_of) as $t
    | select($t != "")
    | {line: $line, role: "user", class: (if $t | test("^\\s*(<pasted_content[^>]*>\\s*)?Chat from ") then "read" else "human" end), tool: null, text: $t}
  elif $e.type == "user" then
    $e.message.content[]? | select(type == "object" and .type == "tool_result") | tool_row($line; $tools)
  elif $e.type == "assistant" then
    ($e.message.content | text_of) as $t
    | select($t != "")
    | {line: $line, role: "assistant", class: "assistant", tool: null, text: $t}
  else empty end
JQ
}

main "$@"
