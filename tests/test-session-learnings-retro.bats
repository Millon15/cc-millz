#!/usr/bin/env bats
#
# tests/test-session-learnings-retro.bats: sl-retro.sh finds Claude and Codex sessions, renders them
# wrapped and redacted with every omission listed, and gates a reader on the Read lines it got back.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	RETRO="${REPO_ROOT}/plugins/session-learnings/scripts/sl-retro.sh"
	cp -R "${REPO_ROOT}/tests/fixtures/session-learnings/retro/home" "$TMP/home"
	export CLAUDE_CONFIG_DIR="$TMP/home/claude" CODEX_HOME="$TMP/home/codex"
	export CLAUDE_CODE_SESSION_ID=44444444-4444-4444-8444-444444444444
	S1=11111111-1111-4111-8111-111111111111
	MAIN="$CLAUDE_CONFIG_DIR/projects/-repo/$S1.jsonl"
}

teardown() { teardown_tmp; }

ids() { jq -r '"\(.harness):\(.session_id[0:8]):\(.status)"' | sort | tr '\n' ' '; }

render_fixture() {
	"$RETRO" render --slug fx --out "$TMP/out" "$@" >"$TMP/render.jsonl"
}

# part <n> <lines>: a rendered part plus a manifest naming it.
part() {
	seq 1 "$1" | sed 's/^/rendered line /' >"$TMP/part.txt"
	jq -n --arg file "$TMP/part.txt" --argjson lines "$1" --arg sha "$(shasum -a 256 "$TMP/part.txt" | cut -d' ' -f1)" \
		'{parts:[{file:$file, lines:$lines, sha256:$sha, omitted:[], source:{}, high_water:null}]}' >"$TMP/manifest.json"
}

# reader <tool> <from> <to> [error]: one tool call on the part and the numbered lines it returned.
reader() {
	local id="toolu_$RANDOM$RANDOM" body
	body="$(seq "$2" "$3" | awk '{printf "%d\trendered line %d\n", $1, $1}')"
	jq -nc --arg id "$id" --arg name "$1" --arg path "$TMP/part.txt" \
		'{type:"assistant", message:{content:[{type:"tool_use", id:$id, name:$name, input:{file_path:$path, command:("sed -n p " + $path)}}]}}'
	jq -nc --arg id "$id" --arg body "$body" --argjson err "${4:-false}" \
		'{type:"user", message:{content:[{type:"tool_result", tool_use_id:$id, content:$body, is_error:$err}]}}'
}

@test "find: Claude and Codex rows, a pruned history row; headless, caller, other projects and guardians stay out" {
	run "$RETRO" find retro --codex --project /repo
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | ids)" = "claude:11111111:ok claude:55555555:pruned codex:01a1aaaa:ok " ]
	[ "$(printf '%s\n' "$output" | jq -r 'select(.status == "pruned") | .path')" = null ]
	[ "$(printf '%s\n' "$output" | jq -r 'select(.session_id[0:8] == "11111111") | .first_prompt')" = "please build the retro flow" ]
}

@test "find: without --codex only Claude is searched; --all-projects widens the scope" {
	[ "$("$RETRO" find retro --project /repo | ids)" = "claude:11111111:ok claude:55555555:pruned " ]
	[ "$("$RETRO" find retro --all-projects | ids)" = "claude:11111111:ok claude:33333333:ok claude:55555555:pruned " ]
}

@test "find: --command matches the command tag and the Skill call, and counts them as hits" {
	run "$RETRO" find --command peer-chat:build --project /repo
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | jq -r '"\(.session_id[0:8]) \(.hits)"')" = "11111111 2" ]
}

@test "find: an explicit id admits a headless run; --since drops older sessions; --include-caller keeps the caller" {
	[ "$("$RETRO" find 22222222 | ids)" = "claude:22222222:ok " ]
	[ "$("$RETRO" find retro --since 2026-11-19 --project /repo | ids)" = "" ]
	[ "$("$RETRO" find retro --since 2026-11-19 --project /repo --include-caller | ids)" = "claude:44444444:ok " ]
}

@test "find: a secret in a first prompt or a history line is redacted before it is printed" {
	jq -nc '{type:"user", timestamp:"2026-11-18T09:40:00Z", cwd:"/repo", entrypoint:"cli", origin:{kind:"human"}, message:{content:"retro with token=SUPERSECRETVALUE123"}}' \
		>"$CLAUDE_CONFIG_DIR/projects/-repo/66666666-6666-4666-8666-666666666666.jsonl"
	jq -nc '{display:"retro password=HISTORYSECRET999", timestamp:1760000000000, project:"/repo", sessionId:"77777777-7777-4777-8777-777777777777"}' >>"$CLAUDE_CONFIG_DIR/history.jsonl"
	jq -nc '{type:"user", timestamp:"2026-11-18T09:41:00Z", cwd:"/repo", entrypoint:"cli", origin:{kind:"human"}, message:{content:"retro ends in token=FAKESECRETVALUE"}}' \
		>"$CLAUDE_CONFIG_DIR/projects/-repo/69696969-6666-4666-8666-666666666666.jsonl"
	run "$RETRO" find retro --project /repo
	[ "$status" -eq 0 ]
	[[ "$output" != *SUPERSECRET* && "$output" != *HISTORYSECRET* && "$output" != *FAKESECRET* ]]
	[ "$(printf '%s\n' "$output" | grep -c 'REDACTED')" -eq 3 ]
}

@test "find: a secret-shaped project path stays intact, so find pipes into render" {
	local dir="$CLAUDE_CONFIG_DIR/projects/-repo-token=synthetic-label"
	mkdir -p "$dir"
	jq -nc '{type:"user", timestamp:"2026-11-18T09:50:00Z", cwd:"/repo/token=synthetic-label", entrypoint:"cli", origin:{kind:"human"}, message:{content:"retro piping check"}}' \
		>"$dir/88888888-8888-4888-8888-888888888888.jsonl"
	"$RETRO" find 'retro piping' --project /repo >"$TMP/rows.jsonl"
	[ "$(jq -r .path "$TMP/rows.jsonl")" = "$dir/88888888-8888-4888-8888-888888888888.jsonl" ]
	[ "$(jq -r .project "$TMP/rows.jsonl")" = "/repo/token=synthetic-label" ]
	"$RETRO" render --slug pipe --out "$TMP/out" <"$TMP/rows.jsonl" >"$TMP/render.jsonl"
	grep -q '^retro piping check$' "$(jq -r .file "$TMP/render.jsonl")"
}

@test "find: no topic, command or id is a usage error; a bad regex is exit 2" {
	run "$RETRO" find
	[ "$status" -eq 2 ]
	run "$RETRO" find '('
	[ "$status" -eq 2 ]
}

@test "render: wraps a long line without clipping, splits at compaction, appends the subagent, strips skill bodies and reminders" {
	render_fixture 11111111
	[ "$(jq -s length "$TMP/render.jsonl")" -eq 2 ]
	local p1="$TMP/out/fx/sessions/claude-$S1-p01.txt" p2="$TMP/out/fx/sessions/claude-$S1-p02.txt"
	[ "$(perl -CSD -ne 'print if length > 1001' "$p2" | wc -l)" -eq 0 ]
	[ "$(sed -n '/^### CLAUDE .* L12$/,/^$/p' "$p2" | sed 1d | sed 's/^↳ //' | tr -d '\n' | tr -cd L | wc -c)" -eq 2600 ]
	head -1 "$p2" | grep -q '^=== COMPACTION L8'
	grep -q '^### USER (queued) .* L10$' "$p2"
	grep -q '^### SUBAGENT agent-r1 "Reader one" spawned at L6$' "$p2"
	! grep -q 'body that must not render\|hidden reminder' "$p1" "$p2"
	grep -q '^please build the retro flow$' "$p1"
}

@test "render: the manifest lists every omitted block once, by kind, source and line, in the part that covers it" {
	render_fixture 11111111 01a1aaaa
	run jq -c '[.parts[] | {f: (.file | split("/") | last), o: [.omitted[] | "\(.kind)@\(.source):\(.source_lines | join(","))"]}]' "$TMP/out/fx/manifest.json"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | grep -qF '{"f":"claude-11111111-1111-4111-8111-111111111111-p01.txt","o":["assistant:thinking@main:5","row:mode@main:1","skill-body@main:3","system-reminder@main:4"]}'
	printf '%s' "$output" | grep -qF '{"f":"claude-11111111-1111-4111-8111-111111111111-p02.txt","o":["attachment:skill_listing@main:11"]}'
	printf '%s' "$output" | grep -qF '{"f":"codex-01a1aaaa-0000-7000-8000-000000000001-p01.txt","o":["codex:injected-context@main:2,3","codex:reasoning@main:7","row:session_meta@main:1"]}'
	[ "$(jq -r '.parts[0] | [.lines, (.sha256 | length), .high_water.lines] | join(" ")' "$TMP/out/fx/manifest.json")" = "20 64 12" ]
}

@test "render: --part-lines splits a long thread into parts no longer than the limit" {
	local n
	for n in $(seq 1 60); do
		jq -nc --arg t "message $n" '{type:"user", timestamp:"2026-11-18T09:00:00Z", cwd:"/repo", entrypoint:"cli", origin:{kind:"human"}, message:{content:$t}}'
	done >>"$MAIN"
	render_fixture 11111111 --part-lines 50
	[ "$(jq -s length "$TMP/render.jsonl")" -ge 4 ]
	[ "$(jq -s 'map(.lines) | max' "$TMP/render.jsonl")" -le 50 ]
	cat "$TMP"/out/fx/sessions/claude-$S1-p*.txt | grep -c '^message ' | grep -qx 60
}

@test "render: secrets are redacted before the hash is taken" {
	jq -nc '{type:"assistant", timestamp:"2026-11-18T09:11:00Z", cwd:"/repo", entrypoint:"cli", message:{content:[{type:"text", text:"token=SUPERSECRETVALUE123 in a log"}]}}' >>"$MAIN"
	render_fixture 11111111
	! grep -rq SUPERSECRET "$TMP/out"
	grep -q 'REDACTED' "$TMP/out/fx/sessions/claude-$S1-p02.txt"
	[ "$(jq -r '.parts[1].sha256' "$TMP/out/fx/manifest.json")" = "$(shasum -a 256 "$TMP/out/fx/sessions/claude-$S1-p02.txt" | cut -d' ' -f1)" ]
}

@test "render: --delta renders only what a live source grew by and moves its high-water mark" {
	render_fixture 11111111
	jq -nc '{type:"user", timestamp:"2026-11-18T09:20:00Z", cwd:"/repo", entrypoint:"cli", origin:{kind:"human"}, message:{content:"a late follow-up"}}' >>"$MAIN"
	"$RETRO" render --slug fx --out "$TMP/out" --delta >"$TMP/delta.jsonl"
	[ "$(jq -r '.file | split("/") | last' "$TMP/delta.jsonl")" = "claude-$S1-d13-2-p01.txt" ]
	grep -q '^a late follow-up$' "$TMP/out/fx/sessions/claude-$S1-d13-2-p01.txt"
	! grep -q 'please build' "$TMP/out/fx/sessions/claude-$S1-d13-2-p01.txt"
	run "$RETRO" render --slug fx --out "$TMP/out" --delta
	[ -z "$output" ]
}

@test "render: --delta also picks up a subagent that grew or appeared, with nothing from the main thread" {
	render_fixture 11111111
	jq -nc '{type:"assistant", timestamp:"2026-11-18T09:00:04.900Z", message:{content:[{type:"text", text:"a late subagent line"}]}}' \
		>>"$CLAUDE_CONFIG_DIR/projects/-repo/$S1/subagents/agent-r1.jsonl"
	"$RETRO" render --slug fx --out "$TMP/out" --delta >"$TMP/delta.jsonl"
	local delta="$TMP/out/fx/sessions/claude-$S1-d13-2-p01.txt"
	grep -q '^### SUBAGENT agent-r1 "Reader one" spawned at L? from S3$' "$delta"
	grep -q '^a late subagent line$' "$delta"
	! grep -q 'subagent finding about retro\|please build' "$delta"
}

@test "render: a partial last record waits for the next --delta instead of being lost" {
	printf '%s' '{"type":"user","timestamp":"2026-11-18T09:30:00Z","cwd":"/repo","entrypoint":"cli","origin":{"kind":"human"},"message":{"content":"half writ' >>"$MAIN"
	render_fixture 11111111
	! grep -rq 'half writ' "$TMP/out/fx/sessions"
	[ "$(jq -r '.parts[0].high_water.lines' "$TMP/out/fx/manifest.json")" -eq 12 ]
	printf '%s\n' 'ten"}}' >>"$MAIN"
	"$RETRO" render --slug fx --out "$TMP/out" --delta >"$TMP/delta.jsonl"
	grep -q '^half written$' "$(jq -r .file "$TMP/delta.jsonl")"
}

@test "render: a stdin row with a path-shaped harness or session id is refused before anything is written" {
	jq -nc --arg p "$MAIN" '{harness:"../../escape", session_id:"11111111", path:$p}' >"$TMP/bad1.jsonl"
	jq -nc --arg p "$MAIN" '{harness:"claude", session_id:"../../../escape", path:$p}' >"$TMP/bad2.jsonl"
	jq -nc '{harness:"claude", session_id:"11111111", path:"/etc/hosts"}' >"$TMP/bad3.jsonl"
	local bad
	for bad in bad1 bad2 bad3; do
		run "$RETRO" render --slug fx --out "$TMP/out" <"$TMP/$bad.jsonl"
		[ "$status" -eq 2 ]
	done
	[ -z "$(find "$TMP" -name '*escape*')" ]
	[ ! -d "$TMP/out/fx/sessions" ]
}

@test "render: --delta refuses a manifest source with a path-shaped harness or session id" {
	render_fixture 11111111
	jq '.parts[0].source.harness = "/tmp/escape-x" | .parts[0].high_water.lines = 1' "$TMP/out/fx/manifest.json" >"$TMP/m.json"
	cp "$TMP/m.json" "$TMP/out/fx/manifest.json"
	run "$RETRO" render --slug fx --out "$TMP/out" --delta
	[ "$status" -eq 2 ]
	jq '.parts[0].source.harness = "claude" | .parts[0].source.session_id = "../../escape"' "$TMP/m.json" >"$TMP/out/fx/manifest.json"
	run "$RETRO" render --slug fx --out "$TMP/out" --delta
	[ "$status" -eq 2 ]
	[ -z "$(find "$TMP" /tmp -maxdepth 3 -name '*escape*' 2>/dev/null)" ]
}

@test "render: a symlinked part path or manifest is refused" {
	mkdir -p "$TMP/out/fx/sessions"
	ln -s "$TMP/elsewhere.txt" "$TMP/out/fx/sessions/claude-$S1-p01.txt"
	run "$RETRO" render --slug fx --out "$TMP/out" "$S1"
	[ "$status" -eq 2 ]
	[ ! -e "$TMP/elsewhere.txt" ]
}

@test "render: two sessions sharing an id prefix never overwrite each other's parts" {
	cp "$MAIN" "$CLAUDE_CONFIG_DIR/projects/-repo/11111111-9999-4111-8111-111111111111.jsonl"
	render_fixture "$S1" 11111111-9999-4111-8111-111111111111
	[ "$(jq -r .file "$TMP/render.jsonl" | sort -u | wc -l)" -eq "$(jq -s length "$TMP/render.jsonl")" ]
}

@test "coverage: a reader that Read every line passes" {
	part 4000
	{ reader Read 1 2000; reader Read 2001 4000; } >"$TMP/reader.jsonl"
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '"\(.covered) \(.ok)"')" = "4000 true" ]
}

@test "coverage: a reader that read 1-400 and 3600-4000 is short by exactly 401-3599" {
	part 4000
	{ reader Read 1 400; reader Read 3600 4000; } >"$TMP/reader.jsonl"
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -c '[.covered, .missing_ranges, .ok]')" = '[801,[[401,3599]],false]' ]
}

@test "coverage: sed or rg output and failed Read results count for nothing" {
	part 300
	{ reader Bash 1 300; reader Grep 1 300; reader Read 1 300 true; reader Read 1 100; } >"$TMP/reader.jsonl"
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -c '[.covered, .missing_ranges]')" = '[100,[[101,300]]]' ]
}

@test "coverage: counts the lines a Read returned, never the limit it asked for" {
	part 300
	reader Read 1 120 | jq -c 'if .type == "assistant" then .message.content[0].input += {offset: 1, limit: 300} else . end' >"$TMP/reader.jsonl"
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -c '.missing_ranges')" = '[[121,300]]' ]
}

@test "coverage: a re-read of the gaps by a second reader unions with the first" {
	part 4000
	{ reader Read 1 400; reader Read 3600 4000; } >"$TMP/first.jsonl"
	reader Read 401 3599 >"$TMP/second.jsonl"
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --transcript "$TMP/first.jsonl" --transcript "$TMP/second.jsonl"
	[ "$status" -eq 0 ]
}

@test "coverage: a Read of the old bytes at the same path counts for nothing after a re-render" {
	part 300
	reader Read 1 300 >"$TMP/reader.jsonl"
	part 300
	sed -i '' 's/^rendered line /re-rendered line /' "$TMP/part.txt"
	jq --arg sha "$(shasum -a 256 "$TMP/part.txt" | cut -d' ' -f1)" '.parts[0].sha256 = $sha' "$TMP/manifest.json" >"$TMP/m2.json"
	run "$RETRO" coverage --manifest "$TMP/m2.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -c '.missing_ranges')" = '[[1,300]]' ]
}

@test "coverage: a missing manifest, an empty one or a missing reader transcript is exit 2, never green" {
	part 10
	reader Read 1 10 >"$TMP/reader.jsonl"
	run "$RETRO" coverage --manifest "$TMP/nope/manifest.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 2 ]
	echo '{"parts": []}' >"$TMP/empty.json"
	run "$RETRO" coverage --manifest "$TMP/empty.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 2 ]
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --transcript "$TMP/nope.jsonl"
	[ "$status" -eq 2 ]
}

@test "coverage: a part whose bytes changed since the manifest is refused" {
	part 300
	reader Read 1 300 >"$TMP/reader.jsonl"
	echo tampered >>"$TMP/part.txt"
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --transcript "$TMP/reader.jsonl"
	[ "$status" -eq 2 ]
	[[ "$output" == *"sha256 mismatch"* ]]
}

@test "coverage: --agent with a parent id prefix finds the subagent transcript" {
	part 50
	reader Read 1 50 >"$CLAUDE_CONFIG_DIR/projects/-repo/$S1/subagents/agent-reader.jsonl"
	run "$RETRO" coverage --manifest "$TMP/manifest.json" --agent reader --parent 11111111
	[ "$status" -eq 0 ]
}

@test "--explain: one JSON object, every value sourced; an unreadable profile is exit 2" {
	git -C "$TMP" init -q proj
	cd "$TMP/proj"
	run "$RETRO" --explain
	[ "$status" -eq 0 ]
	assert_explain_source "$output" claude_dir "detected:CLAUDE_CONFIG_DIR"
	assert_explain_source "$output" codex_dir "detected:CODEX_HOME"
	assert_explain_source "$output" part_lines default
	assert_explain_source "$output" out_root default
	echo '{"retro_part_lines": 1200}' >.session-learnings.json
	assert_explain_source "$("$RETRO" --explain)" part_lines profile
	echo '{broken' >.session-learnings.json
	run "$RETRO" --explain
	[ "$status" -eq 2 ]
}

@test "retro skill body: model-invocable, finder subagents mandatory, coverage gate, approve by id, design hand-off" {
	local skill="${REPO_ROOT}/plugins/session-learnings/skills/retro/SKILL.md"
	grep -qFx 'name: retro' "$skill"
	! grep -q 'disable-model-invocation' "$skill"
	grep -qF '## 2. Find, then let finders read every candidate (mandatory)' "$skill"
	grep -qF 'Only finder' "$skill"
	grep -qF 'The grep hits in the find row are a hint, never a verdict' "$skill"
	grep -qF 'RETRO coverage --manifest' "$skill"
	grep -qF -- '--agent <first>' "$skill"
	grep -qF 'Reply by id: "discuss R2 R5" (peer design), "build R3" (implement), "drop R4".' "$skill"
	grep -qF 'An approval to discuss is not an approval to implement' "$skill"
	grep -qF '/peer-chat:design <out>/<slug>/findings.md --slug <slug>' "$skill"
	! grep -q '/Users/' "$skill"
}
