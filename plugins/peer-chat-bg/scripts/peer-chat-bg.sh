#!/usr/bin/env bash
# --explain emits one side-effect-free JSON config object; otherwise run the protocol helper.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/peer-chat-bg.py" "$@"
