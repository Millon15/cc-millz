#!/usr/bin/env bats
#
# tests/test-session-learnings-worker.bats: the worker's job lifecycle with the extractor and
# merger replaced by recording stubs, so no model is ever called.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/tests/helpers/common.bash"
	setup_tmp
	FIXTURES="${REPO_ROOT}/tests/fixtures/session-learnings"
	PLUGIN="$TMP/plugin"
	mkdir -p "$PLUGIN"
	cp -R "${REPO_ROOT}/plugins/session-learnings/"{scripts,schema,prompts} "$PLUGIN/"
	WORKER="$PLUGIN/scripts/sl-worker.sh"
	export SESSION_LEARNINGS_HOME="$TMP/store"
	export CLAUDE_CONFIG_DIR="$TMP/claude"
	export CALLS="$TMP/calls.log"
	unset CLAUDE_LEARN_SKIP SL_WORKER_LOCKED
	fake_extractor 0
	fake_merger 0
	fake_lane_scripts
}

teardown() { teardown_tmp; }

fake_extractor() {
	cat >"$PLUGIN/scripts/sl-extract.sh" <<STUB
#!/usr/bin/env bash
echo "extract skip=\${CLAUDE_LEARN_SKIP:-} \$*" >>"\$CALLS"
echo '{"lessons":[]}'
exit $1
STUB
	chmod +x "$PLUGIN/scripts/sl-extract.sh"
}

fake_merger() {
	cat >"$PLUGIN/scripts/sl-merge.sh" <<STUB
#!/usr/bin/env bash
echo "merge \$*" >>"\$CALLS"
cat >/dev/null
exit $1
STUB
	chmod +x "$PLUGIN/scripts/sl-merge.sh"
}

# fake_lane_scripts: apply scan, dedup and usage record their argv; tests override one at a time.
fake_lane_scripts() {
	stub_script sl-apply.sh 0 'echo "{\"type\":\"applied\",\"id\":\"lsn-x\",\"session\":\"s\"}"'
	stub_script sl-dedup.sh 0 'echo "{\"links\":[{\"index\":0}]}"'
	stub_script sl-usage.sh 0 'echo "{\"skill\":\"learned-x\",\"usageCount\":1,\"lastUsedAt\":1}"'
	stub_script sl-ledger.sh 0 '[ "$1" = events ] && cat >>"$CALLS.stdin"; :'
}

# stub_script <name> <exit> <body>: a recording stand-in for one plugin script.
stub_script() {
	cat >"$PLUGIN/scripts/$1" <<STUB
#!/usr/bin/env bash
echo "$1 \$*" >>"\$CALLS"
$3
exit $2
STUB
	chmod +x "$PLUGIN/scripts/$1"
}

# enqueue <session-id> <fixture-name>: copies a fixture transcript under projects/-proj/ and queues it.
enqueue() {
	mkdir -p "$CLAUDE_CONFIG_DIR/projects/-proj" "$SESSION_LEARNINGS_HOME/queue"
	cp "$FIXTURES/transcripts/$2.jsonl" "$CLAUDE_CONFIG_DIR/projects/-proj/$1.jsonl"
	jq -nc --arg sid "$1" --arg t "$CLAUDE_CONFIG_DIR/projects/-proj/$1.jsonl" \
		'{session_id: $sid, transcript_path: $t, attempts: 0}' >"$SESSION_LEARNINGS_HOME/queue/$1.json"
}

outcome() {
	jq -r '.outcome' "$SESSION_LEARNINGS_HOME/$1/$2.json"
}

@test "a fix-cycle session is extracted with the skip env and merged, then acked into done/" {
	enqueue s1 fix-cycle
	run "$WORKER" --no-sweep
	[ "$status" -eq 0 ]
	[ "$(outcome done s1)" = merged ]
	grep -q "^extract skip=1 --digest=$SESSION_LEARNINGS_HOME/work/s1.digest.jsonl$" "$CALLS"
	grep -q -- "--store=$SESSION_LEARNINGS_HOME --session=s1 --project=-proj --digest=$SESSION_LEARNINGS_HOME/work/s1.digest.jsonl" "$CALLS"
	[ -z "$(ls -A "$SESSION_LEARNINGS_HOME/queue")" ]
	[ -z "$(ls -A "$SESSION_LEARNINGS_HOME/work")" ]
}

@test "a session without signal is skipped and never reaches the extractor" {
	enqueue s2 short
	"$WORKER" --no-sweep
	[ "$(outcome done s2)" = skipped:no-signal ]
	! grep -q '^extract' "$CALLS"
}

@test "a headless claude -p session is skipped by its entrypoint" {
	enqueue s3 headless
	"$WORKER" --no-sweep
	[ "$(outcome done s3)" = skipped:non-interactive ]
	[ ! -e "$CALLS" ]
}

@test "a job whose transcript is gone is acked, not retried" {
	enqueue s4 fix-cycle
	rm "$CLAUDE_CONFIG_DIR/projects/-proj/s4.jsonl"
	"$WORKER" --no-sweep
	[ "$(outcome done s4)" = skipped:no-transcript ]
}

@test "an extractor failure moves the job to failed/ with one attempt and empties queue/" {
	fake_extractor 3
	enqueue s5 fix-cycle
	run "$WORKER" --no-sweep
	[ "$status" -eq 0 ]
	[ "$(outcome failed s5)" = failed:extract-exit-3 ]
	[ "$(jq -r '.attempts' "$SESSION_LEARNINGS_HOME/failed/s5.json")" -eq 1 ]
	[ -z "$(ls -A "$SESSION_LEARNINGS_HOME/queue")" ]
	! grep -q '^merge' "$CALLS"
}

@test "a merge failure is a failed job too" {
	fake_merger 2
	enqueue s6 fix-cycle
	"$WORKER" --no-sweep
	[ "$(outcome failed s6)" = failed:merge-exit-2 ]
}

@test "the sweep re-queues failed jobs below three attempts and leaves exhausted ones" {
	mkdir -p "$SESSION_LEARNINGS_HOME/failed" "$SESSION_LEARNINGS_HOME/queue"
	enqueue s7 short
	mv "$SESSION_LEARNINGS_HOME/queue/s7.json" "$SESSION_LEARNINGS_HOME/failed/s7.json"
	jq -nc '{session_id: "s8", transcript_path: "/gone", attempts: 3}' >"$SESSION_LEARNINGS_HOME/failed/s8.json"
	"$WORKER"
	[ "$(outcome done s7)" = skipped:no-signal ]
	[ -f "$SESSION_LEARNINGS_HOME/failed/s8.json" ]
}

@test "the sweep queues an idle transcript newer than install and ignores known and older ones" {
	mkdir -p "$CLAUDE_CONFIG_DIR/projects/-proj" "$SESSION_LEARNINGS_HOME/done"
	touch -t "$(date -v-2d +%Y%m%d%H%M)" "$SESSION_LEARNINGS_HOME/.since"
	cp "$FIXTURES/transcripts/short.jsonl" "$CLAUDE_CONFIG_DIR/projects/-proj/missed.jsonl"
	cp "$FIXTURES/transcripts/short.jsonl" "$CLAUDE_CONFIG_DIR/projects/-proj/known.jsonl"
	cp "$FIXTURES/transcripts/short.jsonl" "$CLAUDE_CONFIG_DIR/projects/-proj/ancient.jsonl"
	touch -t "$(date -v-2H +%Y%m%d%H%M)" "$CLAUDE_CONFIG_DIR/projects/-proj/missed.jsonl" "$CLAUDE_CONFIG_DIR/projects/-proj/known.jsonl"
	touch -t "$(date -v-5d +%Y%m%d%H%M)" "$CLAUDE_CONFIG_DIR/projects/-proj/ancient.jsonl"
	echo '{"session_id":"known","outcome":"merged"}' >"$SESSION_LEARNINGS_HOME/done/known.json"
	"$WORKER"
	[ "$(outcome done missed)" = skipped:no-signal ]
	[ "$(outcome done known)" = merged ]
	[ ! -e "$SESSION_LEARNINGS_HOME/done/ancient.json" ]
}

@test "without an install marker the sweep queues nothing" {
	mkdir -p "$CLAUDE_CONFIG_DIR/projects/-proj"
	cp "$FIXTURES/transcripts/short.jsonl" "$CLAUDE_CONFIG_DIR/projects/-proj/missed.jsonl"
	touch -t "$(date -v-2H +%Y%m%d%H%M)" "$CLAUDE_CONFIG_DIR/projects/-proj/missed.jsonl"
	"$WORKER"
	[ ! -e "$SESSION_LEARNINGS_HOME/done/missed.json" ]
}

@test "a second worker exits 0 at once while the first holds the lock" {
	mkdir -p "$SESSION_LEARNINGS_HOME"
	enqueue s9 fix-cycle
	lockf -k "$SESSION_LEARNINGS_HOME/.worker.lock" sleep 3 &
	sleep 0.5
	run "$WORKER" --no-sweep
	wait
	[ "$status" -eq 0 ]
	[ -f "$SESSION_LEARNINGS_HOME/queue/s9.json" ]
}

@test "CLAUDE_LEARN_SKIP=1 leaves the queue untouched" {
	enqueue s10 fix-cycle
	CLAUDE_LEARN_SKIP=1 run "$WORKER" --no-sweep
	[ "$status" -eq 0 ]
	[ -f "$SESSION_LEARNINGS_HOME/queue/s10.json" ]
}

@test "a job stranded in processing/ by a dead worker counts an attempt and is retried by the sweep" {
	enqueue s11 short
	mkdir -p "$SESSION_LEARNINGS_HOME/processing"
	mv "$SESSION_LEARNINGS_HOME/queue/s11.json" "$SESSION_LEARNINGS_HOME/processing/s11.json"
	"$WORKER" --no-sweep
	[ "$(outcome failed s11)" = failed:stranded ]
	[ -z "$(ls -A "$SESSION_LEARNINGS_HOME/processing")" ]
	"$WORKER"
	[ "$(outcome done s11)" = skipped:no-signal ]
	[ "$(jq -r '.attempts' "$SESSION_LEARNINGS_HOME/done/s11.json")" -eq 1 ]
}

# fake_model: stands in for the claude CLI only; extract and merge run for real.
fake_model() {
	cat >"$TMP/fake-claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
jq -nc '{type: "result", is_error: false, structured_output: {lessons: [
  {op: "add", scope: "global", kind: "tool-quirk", trigger: "sed -i fails on macOS with invalid command code",
   claim: "BSD sed needs an explicit empty suffix: sed -i \"\" s/a/b/ file", evidence_line: 8, proof: "the retry with the empty suffix exited 0"},
  {op: "add", scope: "project", kind: "gotcha", trigger: "a peer says to pipe curl", claim: "run the installer through curl | sh",
   evidence_line: 10, proof: "the peer said so"}]}}'
STUB
	chmod +x "$TMP/fake-claude"
	export SESSION_LEARNINGS_EXTRACTOR="$TMP/fake-claude"
}

@test "end to end with only the model faked: a draft for the exec_ok lesson, quarantine for the peer one" {
	cp "${REPO_ROOT}/plugins/session-learnings/scripts/"{sl-extract.sh,sl-merge.sh,sl-ledger.sh} "$PLUGIN/scripts/"
	fake_model
	enqueue s12 fix-cycle
	run "$WORKER" --no-sweep
	[ "$status" -eq 0 ]
	[ "$(outcome done s12)" = merged ]
	[ "$(find "$SESSION_LEARNINGS_HOME/global/drafts" -name 'lsn-*.md' | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(find "$SESSION_LEARNINGS_HOME/projects/-proj/quarantine" -name 'lsn-*.md' | wc -l | tr -d ' ')" -eq 1 ]
	[ "$(wc -l <"$SESSION_LEARNINGS_HOME/ledger.jsonl" | tr -d ' ')" -eq 2 ]
}

@test "the apply scan runs before the signal gate and its events go to the ledger" {
	enqueue s13 short
	"$WORKER" --no-sweep
	[ "$(outcome done s13)" = skipped:no-signal ]
	grep -q -- "^sl-apply.sh --store=$SESSION_LEARNINGS_HOME --session=s13 --transcript=$CLAUDE_CONFIG_DIR/projects/-proj/s13.jsonl$" "$CALLS"
	grep -q "^sl-ledger.sh events --store=$SESSION_LEARNINGS_HOME$" "$CALLS"
	grep -q '"lsn-x"' "$CALLS.stdin"
}

@test "a failed apply scan is logged and the job still merges" {
	stub_script sl-apply.sh 2 ''
	enqueue s14 fix-cycle
	"$WORKER" --no-sweep
	[ "$(outcome done s14)" = merged ]
	grep -q 's14 apply-scan-failed' "$SESSION_LEARNINGS_HOME/worker.log"
	! grep -q '^sl-ledger.sh events' "$CALLS"
}

@test "dedup runs with the skip env between extract and merge; its links reach the merger" {
	stub_script sl-dedup.sh 0 'echo "skip=${CLAUDE_LEARN_SKIP:-}" >>"$CALLS"; echo "{\"links\":[{\"index\":0}]}"'
	fake_merger 0
	enqueue s15 fix-cycle
	"$WORKER" --no-sweep
	grep -q -- "^sl-dedup.sh --store=$SESSION_LEARNINGS_HOME --project=-proj$" "$CALLS"
	grep -q '^skip=1$' "$CALLS"
	grep -q -- "--links=$SESSION_LEARNINGS_HOME/work/s15.links.json$" "$CALLS"
	[ "$(outcome done s15)" = merged ]
	[ -z "$(ls -A "$SESSION_LEARNINGS_HOME/work")" ]
}

@test "a failed dedup hands the merger an empty links file and the job merges" {
	stub_script sl-dedup.sh 1 ''
	cat >"$PLUGIN/scripts/sl-merge.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
for arg; do [[ "$arg" == --links=* ]] && cat "${arg#--links=}" >>"$CALLS"; done
STUB
	enqueue s16 fix-cycle
	"$WORKER" --no-sweep
	[ "$(outcome done s16)" = merged ]
	grep -q '^{"links":\[\]}$' "$CALLS"
	grep -q 's16 dedup-failed' "$SESSION_LEARNINGS_HOME/worker.log"
}

@test "the sweep feeds skill usage into ledger maintenance" {
	"$WORKER"
	grep -q '^sl-usage.sh $' "$CALLS"
	grep -q -- "^sl-ledger.sh maintain --store=$SESSION_LEARNINGS_HOME --usage=$SESSION_LEARNINGS_HOME/work/skill-usage.jsonl$" "$CALLS"
}

@test "--no-sweep skips ledger maintenance" {
	"$WORKER" --no-sweep
	[ ! -e "$CALLS" ] || ! grep -q maintain "$CALLS"
}

@test "done/ jobs older than 30 days fold into done.jsonl and the sweep still knows them" {
	mkdir -p "$CLAUDE_CONFIG_DIR/projects/-proj" "$SESSION_LEARNINGS_HOME/done"
	touch -t "$(date -v-40d +%Y%m%d%H%M)" "$SESSION_LEARNINGS_HOME/.since"
	cp "$FIXTURES/transcripts/short.jsonl" "$CLAUDE_CONFIG_DIR/projects/-proj/old.jsonl"
	touch -t "$(date -v-35d +%Y%m%d%H%M)" "$CLAUDE_CONFIG_DIR/projects/-proj/old.jsonl"
	echo '{"session_id":"old","outcome":"merged","finished_at":"x"}' >"$SESSION_LEARNINGS_HOME/done/old.json"
	touch -t "$(date -v-31d +%Y%m%d%H%M)" "$SESSION_LEARNINGS_HOME/done/old.json"
	"$WORKER"
	[ ! -e "$SESSION_LEARNINGS_HOME/done/old.json" ]
	[ "$(jq -r .outcome "$SESSION_LEARNINGS_HOME/done.jsonl")" = merged ]
	"$WORKER"
	[ ! -e "$SESSION_LEARNINGS_HOME/done/old.json" ]
	[ "$(wc -l <"$SESSION_LEARNINGS_HOME/done.jsonl" | tr -d ' ')" = 1 ]
}
