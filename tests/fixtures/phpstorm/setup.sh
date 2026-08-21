#!/usr/bin/env bash
#
# tests/fixtures/phpstorm/setup.sh <dest>
#
# Builds the project roots the phpstorm suite drives the doctor against. The
# profile has to live AT a project root under a dotfile name, so the fixture
# ships the JSON under plain names here and this script places each copy.
#
#   <dest>/green/       profile with a declared start_cmd + a healthy workspace
#                       file → every check passes
#   <dest>/green/sub/   a subdirectory, for the walk-up
#   <dest>/minimal/     profile with services only → start_cmd and
#                       workspace_file fall back to their defaults
#   <dest>/bare/        no profile at all → the missing-profile case
#
# All content is synthetic: the service, container, port and server names name
# nothing that exists.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:?usage: setup.sh <dest>}"

mkdir -p "${DEST}/green/.idea" "${DEST}/green/sub" "${DEST}/minimal" "${DEST}/bare"

cp "${HERE}/profile.json" "${DEST}/green/.xdebug-doctor.json"
cp "${HERE}/workspace.xml" "${DEST}/green/.idea/workspace.xml"
cp "${HERE}/profile-minimal.json" "${DEST}/minimal/.xdebug-doctor.json"

printf '%s\n' "${DEST}"
