#!/usr/bin/env bash
#
# tests/fixtures/merge-kit/forensics-setup.sh <dest>
#
# Builds the four forensic fixtures under <dest>. Each is a real repository in
# a real state — an interrupted merge is not simulated by writing a MERGE_HEAD
# file, it is produced by running a merge that conflicts, because the shape of
# the state directory is exactly what merge-forensics.sh reads.
#
#   <dest>/in-progress-merge/   a conflicted `git merge`, MERGE_HEAD present
#   <dest>/in-progress-rebase/  a conflicted `git rebase`, rebase state present
#   <dest>/clean-merge/         a finished two-parent merge, no overlap, CLEAN
#   <dest>/squash-merge/        a one-parent squash that DROPPED a target line,
#                               with the source branch still present so the fork
#                               point is recoverable via --source
#
# Every fixture shares one history shape: a fork commit carrying `shared.txt`,
# then work on both sides. What differs is how the two sides are brought back
# together, which is the whole subject of the tool.

set -euo pipefail

dest="${1:?usage: forensics-setup.sh <dest>}"

g() { git -C "${repo}" "$@"; }

new_repo() {
	repo="${dest}/$1"
	mkdir -p "${repo}"
	g init -q -b main
	g config user.email t@example.invalid
	g config user.name t
	g config commit.gpgsign false
	g config core.hooksPath "${dest}/no-hooks"
}

commit_all() { g add -A && g commit -qm "$1"; }

# The fork point every fixture branches from.
seed_fork() {
	printf 'alpha\nbeta\ngamma\n' >"${repo}/shared.txt"
	printf 'untouched\n' >"${repo}/quiet.txt"
	commit_all 'fork: seed'
}

mkdir -p "${dest}/no-hooks"

# ------------------------------------------------- 1. in-progress merge ------
# Both sides edit the same line of shared.txt, so the merge stops with the file
# unmerged and MERGE_HEAD written. That is the state /merge-kit:resolve calls
# the forensics from, before anything is committed.
new_repo in-progress-merge
seed_fork
g checkout -q -b feature
printf 'alpha\nbeta-from-feature\ngamma\n' >"${repo}/shared.txt"
commit_all 'feature: rewrite beta'
g checkout -q main
printf 'alpha\nbeta-from-target\ngamma\n' >"${repo}/shared.txt"
commit_all 'target: rewrite beta'
g merge feature -m 'merge feature' >/dev/null 2>&1 || true

# ------------------------------------------------ 2. in-progress rebase ------
# The same divergence replayed the other way round: the feature branch rebases
# onto the target and stops at the conflicting step, leaving a rebase state
# directory that records the onto ref the fork point is measured against.
new_repo in-progress-rebase
seed_fork
g checkout -q -b feature
printf 'alpha\nbeta-from-feature\ngamma\n' >"${repo}/shared.txt"
commit_all 'feature: rewrite beta'
g checkout -q main
printf 'alpha\nbeta-from-target\ngamma\n' >"${repo}/shared.txt"
commit_all 'target: rewrite beta'
g checkout -q feature
g rebase main >/dev/null 2>&1 || true

# ----------------------------------------------------- 3. clean merge --------
# The two sides touch different files, so the merge reverts nothing. The tool
# must say so plainly rather than hedging: a clean verdict is the common case
# and it has to be cheap.
new_repo clean-merge
seed_fork
g checkout -q -b feature
printf 'feature work\n' >"${repo}/feature-only.txt"
commit_all 'feature: add its own file'
g checkout -q main
printf 'target work\n' >"${repo}/target-only.txt"
commit_all 'target: add its own file'
g merge --no-ff -q feature -m 'merge feature into main'

# ---------------------------------------------------- 4. squash merge --------
# A squash lands the source branch's content as ONE commit with ONE parent, so
# git records no link back to the fork point. Here the squashed content is the
# feature branch's file verbatim, which silently drops the line the target
# gained after the fork — the exact failure this tool exists to catch.
new_repo squash-merge
seed_fork
g checkout -q -b feature
printf 'alpha\nbeta\ngamma\ndelta-from-feature\n' >"${repo}/shared.txt"
commit_all 'feature: append delta'
g checkout -q main
printf 'alpha\nbeta\ngamma\nepsilon-from-target\n' >"${repo}/shared.txt"
commit_all 'target: append epsilon'
printf 'alpha\nbeta\ngamma\ndelta-from-feature\n' >"${repo}/shared.txt"
commit_all 'squash: feature (1 commit)'

printf '%s\n' "${dest}"
