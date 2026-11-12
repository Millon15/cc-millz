#!/usr/bin/env bats

setup() {
    REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    source "$REPO_ROOT/tests/helpers/common.bash"
    setup_tmp
    STATS="$REPO_ROOT/plugins/session-learnings/scripts/sl-stats.sh"
    FIXTURE="$REPO_ROOT/tests/fixtures/session-learnings/stats"
    python3 "$FIXTURE/seed.py" "$TMP"
    STORE="$TMP/store"
    NOW="2026-11-11T10:00:00Z"
    REPORT="$STORE/usage/2026-W46.json"
    SLUG="-Users-test-dev-acme"
}

teardown() { teardown_tmp; }

stats() {
    "$STATS" "$@" --store="$STORE" --projects-dir="$TMP/projects" --config="$TMP/config.json" --now="$NOW"
}

report() {
    run stats report
    assert_status 0
    [ "$output" = "$REPORT" ]
}

proposal_id() {
    stats proposals --status=all | jq -r --arg kind "$1" 'select(.kind == $kind) | .id'
}

write_tools() {
    jq -nc --arg cwd "$TMP/acme" --argjson tools "$1" '{type:"assistant",cwd:$cwd,entrypoint:"cli",
        timestamp:"2026-11-10T10:00:00Z",message:{content:$tools}}' > "$TMP/projects/$SLUG/extra.jsonl"
}

@test "report counts parent sessions, deduplicates tools and excludes window endpoints" {
    report
    jq -e '.sessions == {total:12,interactive:11,headless:1}
        and .week == "2026-W46"
        and .window == {from:"2026-11-04T10:00:00Z",to:"2026-11-11T10:00:00Z",days:7}
        and .skills == [
            {name:"git:commit",loads:2,sessions:1},
            {name:"test:review",loads:1,sessions:1},
            {name:"window:start",loads:1,sessions:1}]
        and .projects[0].sessions == 12' "$REPORT"
}

@test "scripts are relative and hand-rolled commands retain heads without arguments" {
    report
    jq -e '.projects[0].scripts == [
        {path:"bin/check",runs:2,sessions:1}, {path:"tools/task.py",runs:1,sessions:1}]
        and .projects[0].hand_rolled == [{head:"docker exec",runs:12,sessions:3}]' "$REPORT"
    run cat "$REPORT"
    assert_not_contains "$output" secret-argument
    assert_not_contains "$output" never-record
    assert_not_contains "$output" "docker bogus"
}

@test "knowledge counts reads, areas and distinct parent sessions" {
    report
    jq -e '.projects[0].knowledge == [{path:"docs/",reads:5,sessions_reading:1,
        areas:[{area:"docs/guide",reads:4},{area:"docs/",reads:1}],unread_areas:["docs/unused"]}]' "$REPORT"
}

@test "dormant counters match usage reader types and the strict thirty-day cutoff" {
    report
    jq -e '.dormant_skills == [{name:"dormant",last_used:"2026-10-11T10:00:00Z",lifetime:8}]' "$REPORT"
}

@test "report if-stale preserves the current week without reading missing input" {
    report
    cp "$REPORT" "$TMP/original"
    run "$STATS" report --if-stale --store="$STORE" --projects-dir="$TMP/missing" --now="$NOW"
    assert_status 0
    [ "$output" = "$REPORT" ]
    cmp "$REPORT" "$TMP/original"
}

@test "new weeks refresh reports and use the ISO week year" {
    report
    NOW="2026-11-18T10:00:00Z"
    run stats report --if-stale
    assert_status 0
    [ "$output" = "$STORE/usage/2026-W47.json" ]
    NOW="2027-01-01T10:00:00Z"
    run stats report
    assert_status 0
    [ "$output" = "$STORE/usage/2026-W53.json" ]
}

@test "proposals contain deterministic evidence, stable ids and all four kinds" {
    report
    run stats proposals
    assert_status 0
    [ "${#lines[@]}" -eq 4 ]
    jq -se 'map(.kind) == ["dormant-skill","hand-rolled","knowledge-gap","unread-areas"]
        and all(.[]; .status == "open" and .week == "2026-W46" and (.id | test("^prp-[a-f0-9]{12}$")))
        and .[0].project == null and .[0].id == "prp-4940c8f70ee4"
        and .[1].evidence == "12 runs across 3 sessions"
        and .[2].evidence == "1 of 12 sessions read docs/"
        and .[2].id == "prp-f120e3a18e03"' <<< "$output"
    before="$(proposal_id knowledge-gap)"
    jq '.week = "2026-W47"' "$REPORT" > "$STORE/usage/2026-W47.json"
    [ "$(proposal_id knowledge-gap)" = "$before" ]
}

@test "project filtering retains global dormant proposals" {
    report
    run stats proposals --project=another-project
    assert_status 0
    [ "${#lines[@]}" -eq 1 ]
    [ "$(jq -r .kind <<< "$output")" = dormant-skill ]
}

@test "acceptance persists and newest decisions take precedence" {
    report
    id="$(proposal_id knowledge-gap)"
    run stats decide --id="$id" --type=accepted --note="use the existing index"
    assert_status 0
    [ -z "$output" ]
    jq -e --arg id "$id" '. == {event:"accepted", id:$id, note:"use the existing index", ts:"2026-11-11T10:00:00Z"}' "$STORE/proposals.jsonl"
    NOW="2027-11-11T10:00:00Z"
    run stats proposals
    assert_status 0
    assert_not_contains "$output" "$id"
    run stats decide --id="$id" --type=deferred
    assert_status 0
    run stats proposals --status=all
    assert_status 0
    jq -se --arg id "$id" 'map(select(.id == $id))[0].status == "deferred"' <<< "$output"
}

@test "rejections expire at ninety days and deferred proposals need the next report week" {
    report
    rejected="$(proposal_id knowledge-gap)"
    deferred="$(proposal_id hand-rolled)"
    stats decide --id="$rejected" --type=rejected
    stats decide --id="$deferred" --type=deferred
    NOW="2026-11-18T10:00:00Z"
    run stats proposals
    assert_not_contains "$output" "$deferred"
    jq '.week = "2026-W47"' "$REPORT" > "$STORE/usage/2026-W47.json"
    run stats proposals
    assert_contains "$output" "$deferred"
    assert_not_contains "$output" "$rejected"
    NOW="2027-02-09T09:59:59Z"
    run stats proposals
    assert_not_contains "$output" "$rejected"
    NOW="2027-02-09T10:00:00Z"
    run stats proposals
    assert_contains "$output" "$rejected"
}

@test "unknown decisions and invalid CLI inputs use documented exit codes" {
    report
    run stats decide --id=prp-000000000000 --type=rejected
    assert_status 65
    [ ! -e "$STORE/proposals.jsonl" ]
    for args in "" "nonsense" "report --days=0" "decide --id=prp-x" "report --now=bad"; do
        run "$STATS" $args --store="$TMP/unused"
        assert_status 64
    done
    run "$STATS" report --store="$TMP/unused" --projects-dir="$TMP/missing"
    assert_status 66
}

@test "explain walks up to the nearest profile with no store side effects" {
    run stats --explain --project-dir="$TMP/acme/nested/src"
    assert_status 0
    assert_explain_source "$output" knowledge_paths profile
    assert_explain_source "$output" script_dirs profile
    assert_explain_complete "$output"
    [ "$(jq -r .profile_file <<< "$output")" -ef "$TMP/acme/.session-learnings.json" ]
    [ ! -e "$STORE" ]
    printf '%s' '{"knowledge_paths":[],"script_dirs":["tools/"]}' > "$TMP/acme/nested/.session-learnings.json"
    run stats --explain --project-dir="$TMP/acme/nested/src"
    assert_status 0
    jq -e '.values == {knowledge_paths:[],script_dirs:["tools/"]}' <<< "$output"
}

@test "explain detects directories, honors empty overrides and rejects bad profiles" {
    mkdir -p "$TMP/detected/docs" "$TMP/detected/bin" "$TMP/empty"
    run stats --explain --project-dir="$TMP/detected"
    assert_status 0
    assert_explain_source "$output" knowledge_paths detected:docs/
    assert_explain_source "$output" script_dirs detected:bin/
    run stats --explain --project-dir="$TMP/empty"
    assert_status 0
    assert_explain_source "$output" knowledge_paths default
    assert_explain_source "$output" script_dirs default
    for content in '{bad' '[]' '{"knowledge_paths":"docs/"}' '{"script_dirs":["../outside"]}' '{"script_dirs":["/tmp/"]}'; do
        printf '%s' "$content" > "$TMP/empty/.session-learnings.json"
        run stats --explain --project-dir="$TMP/empty"
        assert_status 2
    done
    [ ! -e "$STORE" ]
}

@test "config environment overrides select the same skillUsage file as sl-usage" {
    cp "$TMP/config.json" "$TMP/.claude.json"
    run env CLAUDE_CONFIG_DIR="$TMP" SESSION_LEARNINGS_HOME="$STORE" "$STATS" report --now="$NOW"
    assert_status 0
    jq -e '.sessions.total == 12 and .dormant_skills[0].name == "dormant"' "$REPORT"
}

@test "no report yields no proposals and reading does not create a store" {
    run stats proposals
    assert_status 0
    [ -z "$output" ]
    [ ! -e "$STORE" ]
}

@test "proposal thresholds exclude the quarter boundary and cap qualifying heads at five" {
    report
    jq '.projects[0].knowledge[0].sessions_reading = 3
        | .projects[0].hand_rolled = [
            {head:"excluded count", runs:9, sessions:4}, {head:"excluded sessions",runs:30,sessions:2},
            {head:"tool a",runs:10,sessions:3}, {head:"tool b",runs:10,sessions:3},
            {head:"tool c",runs:10,sessions:3}, {head:"tool d",runs:10,sessions:3},
            {head:"tool e",runs:10,sessions:3}, {head:"tool f",runs:10,sessions:3}]' "$REPORT" > "$STORE/usage/2026-W47.json"
    run stats proposals
    assert_status 0
    assert_not_contains "$output" knowledge-gap
    jq -se 'map(select(.kind == "hand-rolled") | .subject) == ["tool a","tool b","tool c","tool d","tool e"]' <<< "$output"
}

@test "read paths and scripts cannot match a sibling directory or escape the project root" {
    jq --arg root "$TMP/acme" '.message.content = [
        {type:"tool_use",id:"boundary-read",name:"Read",input:{file_path:($root + "/docs-other/index.md")}},
        {type:"tool_use",id:"escape-read",name:"Read",input:{file_path:"../docs/escape.md"}},
        {type:"tool_use",id:"boundary-script",name:"Bash",input:{command:"bin-other/check; ./nested/../bin/check"}}
        ]' "$TMP/projects/$SLUG/main-02.jsonl" | jq -c . > "$TMP/projects/$SLUG/extra.jsonl"
    report
    jq -e '.projects[0].knowledge[0].reads == 5
        and (.projects[0].scripts | all(.[]; .path != "bin-other/check"))
        and (.projects[0].scripts | map(select(.path == "bin/check"))[0].runs == 3)' "$REPORT"
}

@test "inactive projects do not load obsolete malformed profiles" {
    mkdir -p "$TMP/obsolete" "$TMP/projects/obsolete"
    printf '%s' '{bad' > "$TMP/obsolete/.session-learnings.json"
    jq -nc --arg cwd "$TMP/obsolete" '{type:"user",cwd:$cwd,entrypoint:"cli",timestamp:"2020-01-01T00:00:00Z"}' > "$TMP/projects/obsolete/old.jsonl"
    report
    jq -e '.sessions.total == 12' "$REPORT"
}

@test "symlink report targets are refused without changing their destination" {
    mkdir -p "$STORE/usage"
    printf '%s' 'keep this' > "$TMP/target"
    ln -s "$TMP/target" "$REPORT"
    run stats report --if-stale
    assert_status 64
    [ "$(cat "$TMP/target")" = 'keep this' ]
}

@test "parallel decisions append complete events" {
    report
    first="$(proposal_id knowledge-gap)"
    second="$(proposal_id hand-rolled)"
    stats decide --id="$first" --type=rejected &
    first_pid=$!
    stats decide --id="$second" --type=accepted &
    second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
    jq -se --arg a "$first" --arg b "$second" 'length == 2 and (map(.id)|sort) == ([$a,$b]|sort)' "$STORE/proposals.jsonl"
}

@test "redirects, assignments and shell control syntax do not become command heads" {
    command='MODE=fast docker exec worker 2>&1 && docker exec worker &>log; docker exec worker >&2
for item in one two; do docker exec worker; done
if test -f x; then docker exec worker; else docker exec worker; fi
curl https://example.invalid/private?token=hidden
curl --silent https://example.invalid/private?token=hidden'
    write_tools "$(jq -nc --arg command "$command" '[{type:"tool_use",id:"shell",name:"Bash",input:{command:$command}}]')"
    report
    jq -e '.projects[0].hand_rolled == [
        {head:"docker exec",runs:18,sessions:4},
        {head:"curl",runs:1,sessions:1},{head:"curl --silent",runs:1,sessions:1}]' "$REPORT"
    run cat "$REPORT"
    assert_not_contains "$output" token=hidden
}

@test "quoted separators and heredoc bodies do not become commands" {
    command='docker ";" exec; echo "literal && done"
python3 - <<'"'"'PY'"'"'
for thing in data:
    embedded_source(thing)
PY
docker exec worker'
    write_tools "$(jq -nc --arg command "$command" '[{type:"tool_use",id:"heredoc",name:"Bash",input:{command:$command}}]')"
    report
    jq -e '.projects[0].hand_rolled == [
        {head:"docker exec",runs:13,sessions:4},
        {head:"docker",runs:1,sessions:1}]' "$REPORT"
}

@test "interpreter calls count project scripts and skip inline-code modes" {
    command='bash ./bin/task.sh; sh bin/task.sh; zsh bin/task.sh; python bin/task.py; python3 -u bin/task.py
node --require helper bin/task.mjs; bun bin/task.ts; uv run --python 3.12 bin/task.py; uvx bin/task.py
bash -c "bin/inline.sh"; python3 -c "bin/inline.py"; python -m bin/inline.py; node -e "bin/inline.mjs"
python3 -W ignore -c "bin/inline.py"; python3 - bin/stdin-argument.py'
    write_tools "$(jq -nc --arg command "$command" '[{type:"tool_use",id:"interpreters",name:"Bash",input:{command:$command}}]')"
    report
    jq -e '.projects[0].scripts == [
        {path:"bin/task.py",runs:4,sessions:1},{path:"bin/task.sh",runs:3,sessions:1},
        {path:"bin/check",runs:2,sessions:1},{path:"bin/task.mjs",runs:1,sessions:1},
        {path:"bin/task.ts",runs:1,sessions:1},{path:"tools/task.py",runs:1,sessions:1}]
        and (.projects[0].hand_rolled | map(.head)) == ["docker exec"]' "$REPORT"
}

@test "Grep and Glob paths contribute to knowledge read counts" {
    write_tools '[{"type":"tool_use","id":"grep","name":"Grep","input":{"path":"docs/guide","pattern":"needle"}},
        {"type":"tool_use","id":"glob","name":"Glob","input":{"path":"docs/unused","pattern":"*.md"}}]'
    report
    jq -e '.projects[0].knowledge[0] == {path:"docs/",reads:7,sessions_reading:2,
        areas:[{area:"docs/guide",reads:5},{area:"docs/",reads:1},{area:"docs/unused",reads:1}],unread_areas:[]}' "$REPORT"
}

@test "open batches rank dormant skills by lifetime and refill after a decision" {
    report
    jq '.dormant_skills = [range(0;8) | {name:("skill-" + tostring),lifetime:.,last_used:"2026-01-01T00:00:00Z"}]' "$REPORT" > "$STORE/usage/2026-W47.json"
    run stats proposals
    assert_status 0
    jq -se 'map(select(.kind == "dormant-skill") | .subject) == ["skill-7","skill-6","skill-5","skill-4","skill-3"]' <<< "$output"
    first="$(jq -sr 'map(select(.kind == "dormant-skill"))[0].id' <<< "$output")"
    stats decide --id="$first" --type=accepted
    run stats proposals
    assert_status 0
    jq -se 'map(select(.kind == "dormant-skill") | .subject) == ["skill-6","skill-5","skill-4","skill-3","skill-2"]' <<< "$output"
    run stats proposals --status=all
    assert_status 0
    jq -se 'map(select(.kind == "dormant-skill")) | length == 8' <<< "$output"
}

@test "open hand-rolled batches refill in descending run order" {
    report
    jq '.projects[0].hand_rolled = [range(10;18) | {head:("tool " + tostring),runs:.,sessions:3}]' "$REPORT" > "$STORE/usage/2026-W47.json"
    run stats proposals
    assert_status 0
    jq -se 'map(select(.kind == "hand-rolled") | .subject) == ["tool 17","tool 16","tool 15","tool 14","tool 13"]' <<< "$output"
    first="$(jq -sr 'map(select(.kind == "hand-rolled"))[0].id' <<< "$output")"
    stats decide --id="$first" --type=rejected
    run stats proposals
    assert_status 0
    jq -se 'map(select(.kind == "hand-rolled") | .subject) == ["tool 16","tool 15","tool 14","tool 13","tool 12"]' <<< "$output"
}

@test "outside interpreters, pipeline glue and shell builtins do not produce proposals" {
    command='/opt/runtime/bin/node /outside/tool.mjs; bash /outside/tool.sh; uv run /outside/tool.py; uvx remote-tool
awk "{print}"; cut -c1-150; sort; uniq; tee out; tr a b; xargs cat; date; diff a b; comm a b
basename x; dirname x; realpath x; stat x; which x; command -v x; type x; env X=1; export X=1
source file; . file; set -e; unset x; read x; local x; return; exit; break; continue; [ -f x ]; [[ -f x ]]; false
/opt/bin/custom inspect'
    write_tools "$(jq -nc --arg command "$command" '[{type:"tool_use",id:"noise",name:"Bash",input:{command:$command}}]')"
    report
    jq -e '.projects[0].hand_rolled == [
        {head:"docker exec",runs:12,sessions:3}, {head:"custom inspect",runs:1,sessions:1}]' "$REPORT"
    run cat "$REPORT"
    assert_not_contains "$output" /opt/runtime
    assert_not_contains "$output" /opt/bin
    assert_not_contains "$output" /outside/
}
