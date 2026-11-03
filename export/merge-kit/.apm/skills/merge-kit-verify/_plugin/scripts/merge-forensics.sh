#!/usr/bin/env bash
#
# merge-forensics.sh — did this merge silently revert work that landed on the
# target after the fork point?
#
#   merge-forensics.sh --repo <path> <merge-commit> [--fork <ref>] [--source <branch>]
#   merge-forensics.sh --repo <path> --in-progress
#
# git resolves a conflict textually. Where two changes do not overlap line for
# line it merges them without asking, and where one side rewrote a region the
# other side had extended, the extension can vanish with no conflict and no
# notice. Nothing in the merge's own diff shows it: the loss is only visible
# against the fork point, further back than anyone looks.
#
# So every question is answered from three references:
#
#   FORK  where the source branch left the target
#   PRE   the target immediately before the merge
#   POST  the merged result — a commit, or the index and worktree mid-merge
#
# A file changed between FORK and PRE (the target moved) AND between PRE and
# POST (the merge touched it) is AT RISK. For each, the lines PRE has that POST
# lost, intersected with the lines PRE has that FORK never had, are exactly the
# target's own additions the merge dropped.
#
# --repo is mandatory and every git call goes through it: a forensic tool that
# reads whichever repository the shell happens to sit in is worse than none.
#
# Output is one JSON object on stdout. Exit 0 when the analysis ran — the
# verdict lives in the JSON, not in the exit code — and 2 on any usage error.

set -euo pipefail

readonly WORKTREE=WORKTREE

die() {
	printf 'merge-forensics: %s\n' "$1" >&2
	exit 2
}

usage() {
	cat <<'EOF'
usage: merge-forensics.sh --repo <path> <merge-commit> [--fork <ref>] [--source <branch>]
       merge-forensics.sh --repo <path> --in-progress

  --repo <path>       the repository to analyse (mandatory)
  <merge-commit>      a finished merge or squash commit to audit
  --fork <ref>        the fork point, when git cannot recover it
  --source <branch>   the branch that was merged, to recover the fork point from
  --in-progress       audit the merge or rebase currently stopped in the repo

Exit codes: 0 analysed (the verdict is in the JSON) · 2 usage error.
EOF
}

# ------------------------------------------------------------------ args -----

repo=""
commit=""
fork_ref=""
source_branch=""
in_progress=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--repo)
		repo="${2:-}"
		shift
		;;
	--fork)
		fork_ref="${2:-}"
		shift
		;;
	--source)
		source_branch="${2:-}"
		shift
		;;
	--in-progress) in_progress=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "unknown argument: $1" ;;
	*)
		if [ -n "${commit}" ]; then
			die "more than one commit given: ${commit} and $1"
		fi
		commit="$1"
		;;
	esac
	shift
done

if [ -z "${repo}" ]; then
	usage >&2
	exit 2
fi
if [ ! -d "${repo}" ]; then
	die "no such directory: ${repo}"
fi
command -v jq >/dev/null 2>&1 || die 'jq is required and is not on PATH'

g() { git -C "${repo}" "$@"; }

g rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: ${repo}"

if [ "${in_progress}" -eq 1 ] && [ -n "${commit}" ]; then
	die 'pass either a merge commit or --in-progress, not both'
fi
if [ "${in_progress}" -eq 0 ] && [ -z "${commit}" ]; then
	usage >&2
	exit 2
fi

# ----------------------------------------------------- the three references --

git_dir="$(g rev-parse --absolute-git-dir)"

resolve_in_progress() {
	local onto orig state
	if [ -f "${git_dir}/MERGE_HEAD" ]; then
		mode=in-progress-merge
		pre="$(g rev-parse HEAD)"
		post="${WORKTREE}"
		fork="$(g merge-base HEAD MERGE_HEAD)"
		return 0
	fi
	for state in rebase-merge rebase-apply; do
		if [ -d "${git_dir}/${state}" ]; then
			# The rebase records what it is replaying ONTO; that ref is the
			# target state the replayed commits are measured against.
			onto="$(cat "${git_dir}/${state}/onto")"
			orig="$(cat "${git_dir}/${state}/orig-head")"
			mode=in-progress-rebase
			pre="$(g rev-parse "${onto}")"
			post="${WORKTREE}"
			fork="$(g merge-base "${onto}" "${orig}")"
			return 0
		fi
	done
	die 'no merge or rebase in progress: no MERGE_HEAD and no rebase state directory'
}

resolve_commit() {
	local parents count
	g rev-parse --verify --quiet "${commit}^{commit}" >/dev/null ||
		die "not a commit in ${repo}: ${commit}"
	parents="$(g show --no-patch --format='%P' "${commit}")"
	count="$(printf '%s\n' "${parents}" | wc -w | tr -d ' ')"

	post="$(g rev-parse "${commit}")"
	pre="$(g rev-parse "${commit}^1")"

	if [ -n "${fork_ref}" ]; then
		mode=$([ "${count}" -ge 2 ] && printf 'merge' || printf 'squash')
		fork="$(g rev-parse "${fork_ref}^{commit}")" ||
			die "not a commit in ${repo}: ${fork_ref}"
		return 0
	fi

	if [ -n "${source_branch}" ]; then
		mode=$([ "${count}" -ge 2 ] && printf 'merge' || printf 'squash')
		g rev-parse --verify --quiet "${source_branch}^{commit}" >/dev/null ||
			die "not a branch or commit in ${repo}: ${source_branch}"
		fork="$(g merge-base "${pre}" "${source_branch}")"
		return 0
	fi

	# A squash lands one commit with one parent: git records no link back to
	# the source branch, so the fork point is not recoverable from the graph.
	# Guessing it would produce a confident and wrong answer.
	if [ "${count}" -lt 2 ]; then
		die 'squash merge: pass --fork or --source'
	fi

	mode=merge
	fork="$(g merge-base "${commit}^1" "${commit}^2")"
}

if [ "${in_progress}" -eq 1 ]; then
	resolve_in_progress
else
	resolve_commit
fi

# --------------------------------------------------------------- inventory --

# -w throughout: a reindent is not a reversion, and counting it as one is how a
# forensic tool trains its reader to ignore it.
changed_between() {
	g diff -w --name-only "$1" "$2"
}

changed_since() {
	g diff -w --name-only "$1"
}

if [ "${post}" = "${WORKTREE}" ]; then
	merge_changed="$(changed_since "${pre}")"
else
	merge_changed="$(changed_between "${pre}" "${post}")"
fi
target_changed="$(changed_between "${fork}" "${pre}")"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

printf '%s\n' "${target_changed}" | sed '/^$/d' | sort >"${work}/target.txt"
printf '%s\n' "${merge_changed}" | sed '/^$/d' | sort >"${work}/merge.txt"
comm -12 "${work}/target.txt" "${work}/merge.txt" >"${work}/at-risk.txt"

# ------------------------------------------------------------- the analysis --

# Leading indentation and blank lines carry no claim, so they are normalised
# away before the sets are compared; otherwise a re-indented block reads as a
# whole file lost and re-added.
normalise() {
	sed 's/^[[:space:]]*//' | sed '/^$/d' | sort
}

content_at() {
	local rev="$1" file="$2"
	if [ "${rev}" = "${WORKTREE}" ]; then
		cat "${repo}/${file}" 2>/dev/null || true
	else
		g show "${rev}:${file}" 2>/dev/null || true
	fi
}

# A file the target changed whose merged content is byte-for-byte the fork's:
# the target's work on it is gone in full, not line by line.
unchanged_from_fork() {
	local file="$1"
	if [ "${post}" = "${WORKTREE}" ]; then
		g diff -w --quiet "${fork}" -- "${file}" 2>/dev/null
	else
		g diff -w --quiet "${fork}" "${post}" -- "${file}" 2>/dev/null
	fi
}

: >"${work}/full-reverts.txt"
while IFS= read -r file; do
	[ -n "${file}" ] || continue
	if unchanged_from_fork "${file}"; then
		printf '%s\n' "${file}" >>"${work}/full-reverts.txt"
	fi
done <"${work}/target.txt"

: >"${work}/lost.ndjson"
while IFS= read -r file; do
	[ -n "${file}" ] || continue
	content_at "${pre}" "${file}" | normalise >"${work}/pre.lines"
	content_at "${post}" "${file}" | normalise >"${work}/post.lines"
	content_at "${fork}" "${file}" | normalise >"${work}/fork.lines"

	# removed by the merge, intersected with added by the target = lost.
	comm -23 "${work}/pre.lines" "${work}/post.lines" >"${work}/removed.lines"
	comm -23 "${work}/pre.lines" "${work}/fork.lines" >"${work}/added.lines"
	comm -12 "${work}/removed.lines" "${work}/added.lines" >"${work}/lost.lines"

	if [ -s "${work}/lost.lines" ]; then
		jq -Rn --arg file "${file}" '
            [inputs | select(length > 0)] as $lines
            | { file: $file, count: ($lines | length), lines: $lines }
        ' <"${work}/lost.lines" >>"${work}/lost.ndjson"
	fi
done <"${work}/at-risk.txt"

# ----------------------------------------------------------------- report ----

as_array() { jq -Rn '[inputs | select(length > 0)]' <"$1"; }

jq -n \
	--arg repo "$(cd "${repo}" && pwd -P)" \
	--arg mode "${mode}" \
	--arg fork "${fork}" \
	--arg pre "${pre}" \
	--arg post "${post}" \
	--argjson at_risk "$(as_array "${work}/at-risk.txt")" \
	--argjson full_reverts "$(as_array "${work}/full-reverts.txt")" \
	--argjson lost "$(jq -s '.' <"${work}/lost.ndjson")" \
	--argjson target_count "$(wc -l <"${work}/target.txt" | tr -d ' ')" \
	--argjson merge_count "$(wc -l <"${work}/merge.txt" | tr -d ' ')" '
    {
        repo: $repo,
        mode: $mode,
        fork: $fork,
        pre: $pre,
        post: $post,
        target_changed: $target_count,
        merge_changed: $merge_count,
        at_risk: $at_risk,
        full_reverts: $full_reverts,
        lost_lines: $lost,
        verdict: (if ($full_reverts | length) > 0 or ($lost | length) > 0
                  then "FINDINGS" else "CLEAN" end)
    }'
