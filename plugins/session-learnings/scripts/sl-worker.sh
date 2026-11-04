#!/usr/bin/env bash
# sl-worker.sh: drain the session queue: digest → signal → extract → merge, one job at a time.
#
# Run by launchd (QueueDirectories on queue/, plus an hourly StartInterval) or by hand.
# Job lifecycle, all moves are renames inside the store:
#   queue/ ──claim──▶ processing/ ──merge exit 0 or skip──▶ done/
#                                 └──any failure──────────▶ failed/   (sweep re-queues while attempts < 3)
# A job leaves queue/ in every outcome, otherwise launchd would re-fire forever.
#
# Flags: --no-sweep skips the missed-session sweep and the failed-job retry.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE="${SESSION_LEARNINGS_HOME:-$HOME/.claude/learnings}"
PROJECTS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
MAX_ATTEMPTS=3
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
	local session_id="$1" transcript="$2" digest="$3" candidates rc=0
	candidates="$STORE/work/$session_id.candidates.json"
	CLAUDE_LEARN_SKIP=1 "$SCRIPTS_DIR/sl-extract.sh" --digest="$digest" >"$candidates" || rc=$?
	[ "$rc" -eq 0 ] || {
		echo "failed:extract-exit-$rc"
		return 1
	}
	"$SCRIPTS_DIR/sl-merge.sh" --store="$STORE" --session="$session_id" \
		--project="$(project_slug "$transcript")" --digest="$digest" <"$candidates" || rc=$?
	[ "$rc" -eq 0 ] || {
		echo "failed:merge-exit-$rc"
		return 1
	}
	discard "$digest" "$candidates"
	echo "merged"
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
	return 1
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
