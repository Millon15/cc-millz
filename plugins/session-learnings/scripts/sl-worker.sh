#!/usr/bin/env bash
# sl-worker.sh: drain the session queue: apply scan → digest → signal → extract → dedup → merge, one job at a time.
#
# Run by launchd (QueueDirectories on queue/, plus an hourly StartInterval) or by hand.
# Job lifecycle, all moves are renames inside the store:
#   queue/ ──claim──▶ processing/ ──merge exit 0 or skip──▶ done/
#                                 └──any failure──────────▶ failed/   (sweep re-queues while attempts < 3)
# A job leaves queue/ in every outcome, otherwise launchd would re-fire forever.
#
# Flags: --no-sweep skips the sweep: failed-job retry, missed sessions, ledger maintenance, done/ rotation.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE="${SESSION_LEARNINGS_HOME:-$HOME/.claude/learnings}"
PROJECTS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
MAX_ATTEMPTS=3
DONE_KEEP_DAYS=30
SWEEP_IDLE_MINUTES="${SESSION_LEARNINGS_SWEEP_IDLE_MINUTES:-60}"
INTERACTIVE_ENTRYPOINTS='["cli","claude-desktop"]'

main() {
	[ "${CLAUDE_LEARN_SKIP:-}" = 1 ] && exit 0
	ensure_store
	[ "${SL_WORKER_LOCKED:-}" = 1 ] || rerun_under_lock "$@"
	recover_stranded_jobs
	[ "${1:-}" = --no-sweep ] || sweep
	drain_queue
}

ensure_store() {
	mkdir -p "$STORE"/{queue,processing,done,failed,work,tmp}
}

# A second worker exits 0 at once (lock busy = 75); the holder keeps draining until queue/ is empty.
rerun_under_lock() {
	local lock="$STORE/.worker.lock" rc=0
	export SL_WORKER_LOCKED=1
	if command -v flock >/dev/null 2>&1; then
		flock -n -E 75 "$lock" "$0" "$@" || rc=$?
	else
		lockf -k -t 0 "$lock" "$0" "$@" || rc=$?
	fi
	[ "$rc" -eq 75 ] && exit 0
	exit "$rc"
}

sweep() {
	requeue_failed_jobs
	enqueue_missed_sessions
	maintain_ledger
	rotate_done_jobs
}

drain_queue() {
	local job
	while job="$(next_job)"; do
		process_job "$job"
	done
}

next_job() {
	local job
	for job in "$STORE"/queue/*.json; do
		[ -f "$job" ] && {
			printf '%s\n' "$job"
			return 0
		}
	done
	return 1
}

process_job() {
	local queued="$1" claimed outcome
	claimed="$STORE/processing/$(basename "$queued")"
	mv -f "$queued" "$claimed"
	if outcome="$(run_pipeline "$claimed")"; then
		finish_job "$claimed" "done" "$outcome"
		return 0
	fi
	finish_job "$claimed" failed "$outcome"
}

run_pipeline() {
	local job="$1" session_id transcript digest
	session_id="$(jq -r '.session_id' "$job")"
	transcript="$(jq -r '.transcript_path' "$job")"
	digest="$STORE/work/$session_id.digest.jsonl"
	[ -r "$transcript" ] || {
		echo "skipped:no-transcript"
		return 0
	}
	is_interactive_session "$transcript" || {
		echo "skipped:non-interactive"
		return 0
	}
	record_applications "$session_id" "$transcript"
	"$SCRIPTS_DIR/sl-digest.sh" "$transcript" >"$digest" || {
		echo "failed:digest"
		return 1
	}
	"$SCRIPTS_DIR/sl-signal.sh" "$digest" >/dev/null || {
		discard "$digest"
		echo "skipped:no-signal"
		return 0
	}
	extract_and_merge "$session_id" "$transcript" "$digest"
}

extract_and_merge() {
	local session_id="$1" transcript="$2" digest="$3" candidates links project rc=0
	candidates="$STORE/work/$session_id.candidates.json"
	project="$(project_slug "$transcript")"
	CLAUDE_LEARN_SKIP=1 "$SCRIPTS_DIR/sl-extract.sh" --digest="$digest" >"$candidates" || rc=$?
	[ "$rc" -eq 0 ] || {
		echo "failed:extract-exit-$rc"
		return 1
	}
	links="$(find_links "$session_id" "$project" "$candidates")"
	"$SCRIPTS_DIR/sl-merge.sh" --store="$STORE" --session="$session_id" \
		--project="$project" --digest="$digest" --links="$links" <"$candidates" || rc=$?
	[ "$rc" -eq 0 ] || {
		echo "failed:merge-exit-$rc"
		return 1
	}
	discard "$digest" "$candidates" "$links"
	echo "merged"
}

# Applications are telemetry: a failed scan is logged and never blocks learning from the session.
record_applications() {
	local events="$STORE/work/$1.applied.jsonl"
	{ "$SCRIPTS_DIR/sl-apply.sh" --store="$STORE" --session="$1" --transcript="$2" >"$events" &&
		"$SCRIPTS_DIR/sl-ledger.sh" events --store="$STORE" <"$events"; } || log "$1 apply-scan-failed"
	discard "$events"
}

# A failed judge costs only links: the lessons still merge, as new cards.
find_links() {
	local links="$STORE/work/$1.links.json"
	CLAUDE_LEARN_SKIP=1 "$SCRIPTS_DIR/sl-dedup.sh" --store="$STORE" --project="$2" <"$3" >"$links" || {
		log "$1 dedup-failed"
		echo '{"links":[]}' >"$links"
	}
	printf '%s\n' "$links"
}

maintain_ledger() {
	local usage="$STORE/work/skill-usage.jsonl"
	"$SCRIPTS_DIR/sl-usage.sh" >"$usage" || : >"$usage"
	"$SCRIPTS_DIR/sl-ledger.sh" maintain --store="$STORE" --usage="$usage" || log "maintain-failed"
	discard "$usage"
}

# Old done/ jobs fold into done.jsonl, which is_known_session still reads, so the sweep never re-queues them.
rotate_done_jobs() {
	local job
	while IFS= read -r job; do
		jq -c '{session_id, outcome, finished_at}' "$job" >>"$STORE/done.jsonl" && discard "$job"
	done < <(find "$STORE/done" -name '*.json' -mtime "+$DONE_KEEP_DAYS" 2>/dev/null)
}

is_interactive_session() {
	local entrypoint
	entrypoint="$(jq -r 'select(.entrypoint) | .entrypoint' "$1" 2>/dev/null | head -n 1)"
	jq -e --arg e "$entrypoint" 'index($e) != null' <<<"$INTERACTIVE_ENTRYPOINTS" >/dev/null
}

# Claude Code files a transcript under projects/<slug>/; reuse its slug, it already folds worktrees.
project_slug() {
	basename "$(dirname "$1")"
}

finish_job() {
	local claimed="$1" bucket="$2" outcome="$3" attempts
	attempts="$(jq -r '.attempts // 0' "$claimed")"
	[ "$bucket" = failed ] && attempts=$((attempts + 1))
	jq -c --arg outcome "$outcome" --argjson attempts "$attempts" --arg at "$(now)" \
		'. + {outcome: $outcome, attempts: $attempts, finished_at: $at}' "$claimed" >"$STORE/tmp/finish.json"
	mv -f "$STORE/tmp/finish.json" "$STORE/$bucket/$(basename "$claimed")"
	discard "$claimed"
	log "$(basename "$claimed" .json) $bucket $outcome"
}

# Under the lock nothing is in flight, so a job left in processing/ belongs to a worker that died.
recover_stranded_jobs() {
	local job
	for job in "$STORE"/processing/*.json; do
		[ -f "$job" ] || continue
		finish_job "$job" failed "failed:stranded"
	done
}

requeue_failed_jobs() {
	local job
	for job in "$STORE"/failed/*.json; do
		[ -f "$job" ] || continue
		[ "$(jq -r '.attempts // 0' "$job")" -lt "$MAX_ATTEMPTS" ] || continue
		mv -f "$job" "$STORE/queue/$(basename "$job")"
	done
}

# Catches sessions whose SessionEnd never fired (a closed terminal), idle for an hour, newer than install.
enqueue_missed_sessions() {
	[ -f "$STORE/.since" ] && [ -d "$PROJECTS_DIR" ] || return 0
	local transcript session_id
	while IFS= read -r transcript; do
		session_id="$(basename "$transcript" .jsonl)"
		is_known_session "$session_id" && continue
		enqueue_swept "$session_id" "$transcript"
	done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name '*.jsonl' \
		-newer "$STORE/.since" -mmin "+$SWEEP_IDLE_MINUTES" 2>/dev/null)
}

is_known_session() {
	local bucket
	[[ "$1" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 0
	for bucket in queue processing "done" failed; do
		[ -e "$STORE/$bucket/$1.json" ] && return 0
	done
	grep -qF "\"session_id\":\"$1\"," "$STORE/done.jsonl" 2>/dev/null
}

enqueue_swept() {
	jq -nc --arg sid "$1" --arg path "$2" --arg ts "$(now)" \
		'{session_id: $sid, transcript_path: $path, cwd: null, reason: "sweep", ts: $ts, source: "sweep", attempts: 0}' \
		>"$STORE/tmp/sweep.json"
	mv -f "$STORE/tmp/sweep.json" "$STORE/queue/$1.json"
}

discard() {
	rm -f -- "$@"
}

now() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
	printf '%s %s\n' "$(now)" "$1" >>"$STORE/worker.log"
}

main "$@"
