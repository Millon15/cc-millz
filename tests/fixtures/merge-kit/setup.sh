#!/usr/bin/env bash
#
# tests/fixtures/merge-kit/setup.sh <dest>
#
# Builds the profile-resolution fixtures under <dest>. A git repository cannot
# be committed inside another git repository, so the fixture ships plain files
# (repos/, profile.json, origin-urls.txt) and this script turns them into real
# repos with real origin remotes inside a bats temp dir.
#
# What it builds:
#
#   <dest>/workspace/            git repo, github origin, NO profile
#     ├── node-repo/             git repo, github origin, package.json + lockfile
#     ├── go-repo/               git repo, bitbucket origin, go.mod
#     ├── make-repo/             git repo, gitlab origin, Makefile BESIDE a package.json
#     └── quiet-repo/            git repo, unknown host, no build file at all
#   <dest>/profile-workspace/    the same tree plus a committed .merge-kit.json
#   <dest>/bad-profile/          git repo whose .merge-kit.json is not JSON
#   <dest>/no-git/               an empty directory — nothing to detect
#
# The origin URLs come from origin-urls.txt, which is also the truth table the
# forge suite asserts against, so the fixture and the expectation cannot drift.

set -euo pipefail

dest="${1:?usage: setup.sh <dest>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A fixture repo must never inherit the developer's global git config: an
# identity, a signing key or a hooks path from outside would make the fixture
# behave differently on two machines.
init_repo() {
	local dir="$1" origin="$2"
	mkdir -p "${dir}"
	git -C "${dir}" init -q
	git -C "${dir}" config user.email t@example.invalid
	git -C "${dir}" config user.name t
	git -C "${dir}" config commit.gpgsign false
	git -C "${dir}" config core.hooksPath "${dest}/no-hooks"
	if [ -n "${origin}" ]; then
		git -C "${dir}" remote add origin "${origin}"
	fi
	git -C "${dir}" add -A 2>/dev/null
	git -C "${dir}" commit -qm 'fixture' --allow-empty
}

origin_for() {
	awk -v want="$1" '$0 !~ /^#/ && NF == 2 && $1 ~ want { print $1; exit }' "${here}/origin-urls.txt"
}

build_workspace() {
	local root="$1"
	mkdir -p "${root}"
	cp -R "${here}/repos/node-repo" "${here}/repos/go-repo" "${here}/repos/make-repo" \
		"${here}/repos/quiet-repo" "${root}/"
	printf 'workspace root\n' >"${root}/README-fixture.md"

	init_repo "${root}/node-repo" "$(origin_for 'github.com:acme/node-repo')"
	init_repo "${root}/go-repo" "$(origin_for 'bitbucket.org/acme/go-repo')"
	init_repo "${root}/make-repo" "$(origin_for 'gitlab.com:acme/make-repo')"
	init_repo "${root}/quiet-repo" "$(origin_for 'codeberg.invalid')"
	init_repo "${root}" "$(origin_for 'github.com/acme/https-clone')"
}

mkdir -p "${dest}/no-hooks" "${dest}/no-git"

build_workspace "${dest}/workspace"

build_workspace "${dest}/profile-workspace"
cp "${here}/profile.json" "${dest}/profile-workspace/.merge-kit.json"
git -C "${dest}/profile-workspace" add -A
git -C "${dest}/profile-workspace" commit -qm 'fixture: profile'

init_repo "${dest}/bad-profile" "$(origin_for 'github.com:acme/node-repo')"
printf 'this is not json {\n' >"${dest}/bad-profile/.merge-kit.json"

printf '%s\n' "${dest}"
