#!/usr/bin/env bash
#
# tests/fixtures/toolsmith/setup.sh <dest>
#
# Builds the layout fixtures under <dest>. Two of them cannot be committed as
# they are: an EMPTY directory has nothing for git to track, and the layouts
# themselves live under dot-directories that would be easy to lose in a review.
# So the fixture ships its content in plain paths (rulesync/, plugin/, plain/,
# decoy/, ranking/) and this script assembles the real shapes here.
#
# <dest> must be a temp dir with NO agent-config marker above it: the adapter
# walks upwards, so building these inside the repo would let the repo's own
# CLAUDE.md answer for the unmarked fixture.
#
# What it builds:
#
#   <dest>/rulesync-layout/   rulesync.jsonc + .rulesync/{skills,commands,subagents,rules}
#                             a committed .toolsmith.json, a staged-plugin registry,
#                             a justfile, and a generated .claude/ copy
#   <dest>/plugin-layout/     .claude-plugin/plugin.json + skills/commands/agents, a Makefile
#   <dest>/plain-agent/       AGENTS.md + .claude/{skills,commands}
#   <dest>/decoy-repo/        rulesync layout declaring /man and /toolsmith:create
#   <dest>/ranking-layout/    plain layout holding the four ranking skills
#   <dest>/unmarked/          an empty directory — no marker, the usage error
#   <dest>/bad-profile/       a marked directory whose .toolsmith.json is not JSON

set -euo pipefail

dest="${1:?usage: setup.sh <dest>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "${dest}"

# ---------------------------------------------------------- rulesync layout --

rs="${dest}/rulesync-layout"
mkdir -p "${rs}/.rulesync"
cp "${here}/rulesync/config.jsonc" "${rs}/rulesync.jsonc"
cp -R "${here}/rulesync/skills" "${here}/rulesync/commands" \
	"${here}/rulesync/subagents" "${here}/rulesync/rules" "${rs}/.rulesync/"
cp "${here}/rulesync/staged-plugins.json" "${rs}/.rulesync/.staged-plugins.json"
cp "${here}/profile.json" "${rs}/.toolsmith.json"
printf 'default:\n\t@echo fixture\n' >"${rs}/justfile"

# The generated half of the layout: the same skill, fanned out to an agent dir.
# A linter pointed at this copy must say "edit the source instead".
mkdir -p "${rs}/.claude/skills"
cp -R "${here}/rulesync/skills/pdf-extractor" "${rs}/.claude/skills/"

# ------------------------------------------------------------ plugin layout --

pl="${dest}/plugin-layout"
mkdir -p "${pl}/.claude-plugin"
cp "${here}/plugin/plugin.json" "${pl}/.claude-plugin/plugin.json"
cp -R "${here}/plugin/skills" "${here}/plugin/commands" "${here}/plugin/agents" "${pl}/"
printf 'test:\n\t@echo fixture\n' >"${pl}/Makefile"

# ------------------------------------------------------------- plain layout --

pa="${dest}/plain-agent"
mkdir -p "${pa}/.claude"
cp "${here}/plain/AGENTS.md" "${pa}/AGENTS.md"
cp -R "${here}/plain/skills" "${here}/plain/commands" "${pa}/.claude/"

# --------------------------------------------------------------- the decoy ---

dc="${dest}/decoy-repo"
mkdir -p "${dc}/.rulesync"
cp "${here}/rulesync/config.jsonc" "${dc}/rulesync.jsonc"
cp -R "${here}/decoy/commands" "${dc}/.rulesync/"

# ------------------------------------------------------------- the ranking ---

rk="${dest}/ranking-layout"
mkdir -p "${rk}/.claude"
cp "${here}/plain/AGENTS.md" "${rk}/AGENTS.md"
cp -R "${here}/ranking/skills" "${rk}/.claude/"

# --------------------------------------------------------- the error cases ---

mkdir -p "${dest}/unmarked"

bp="${dest}/bad-profile"
mkdir -p "${bp}"
cp "${here}/plain/AGENTS.md" "${bp}/AGENTS.md"
printf 'this is not json {\n' >"${bp}/.toolsmith.json"

printf '%s\n' "${dest}"
