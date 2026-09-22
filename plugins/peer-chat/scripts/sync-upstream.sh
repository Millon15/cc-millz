#!/usr/bin/env bash
# sync-upstream — re-vendor the two-agent-chat recipe from umputun/agterm and show what moved.
#
#   sync-upstream.sh [ref]   # default ref: master; prints a diffstat, writes UPSTREAM.md
#
# Vendored verbatim: scripts/vendor/peer-chat.py (the engine the local scripts/peer-chat.py adapts)
# and tests/fixtures/peer-chat/test_peer_chat.py (the test lives at the repo root, see CLAUDE.md §
# Tests). Written to a staging dir for hand-merging: skills/peer-chat/SKILL.md is one body for every
# harness, merged from upstream's SKILL-claude.md and SKILL-codex.md, so both land in upstream/ and
# the diff is yours to fold in. UPSTREAM.md pins the sha256 of each verbatim file.
#
# Needs gh (authenticated) — the raw endpoint is rate-limited without it.
set -eu

REF="${1:-master}"
REPO="umputun/agterm"
UPSTREAM_DIR="cookbook/two-agent-chat"
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
STAGE="$PLUGIN_ROOT/upstream"

fetch() {
    gh api "repos/$REPO/contents/$UPSTREAM_DIR/$1?ref=$REF" --jq '.content' | base64 -d
}

resolve_sha() {
    gh api "repos/$REPO/commits?path=$UPSTREAM_DIR&sha=$REF&per_page=1" --jq '.[0].sha'
}

vendor_verbatim() {
    fetch peer-chat.py >"$PLUGIN_ROOT/scripts/vendor/peer-chat.py"
    chmod +x "$PLUGIN_ROOT/scripts/vendor/peer-chat.py"
    fetch test_peer_chat.py >"$REPO_ROOT/tests/fixtures/peer-chat/test_peer_chat.py"
}

stage_for_merge() {
    mkdir -p "$STAGE"
    fetch SKILL-claude.md >"$STAGE/SKILL-claude.md"
    fetch SKILL-codex.md >"$STAGE/SKILL-codex.md"
    fetch README.md >"$STAGE/README.md"
}

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

write_provenance() {
    local sha="$1" engine fixture
    engine="$(sha256_of "$PLUGIN_ROOT/scripts/vendor/peer-chat.py")"
    fixture="$(sha256_of "$REPO_ROOT/tests/fixtures/peer-chat/test_peer_chat.py")"
    cat >"$PLUGIN_ROOT/UPSTREAM.md" <<EOF
# Upstream

Vendored from https://github.com/$REPO/tree/$sha/$UPSTREAM_DIR (MIT).

| local file | upstream file | how | sha256 |
| --- | --- | --- | --- |
| scripts/vendor/peer-chat.py | peer-chat.py | verbatim | $engine |
| tests/fixtures/peer-chat/test_peer_chat.py (repo root) | test_peer_chat.py | verbatim | $fixture |
| skills/peer-chat/SKILL.md | SKILL-claude.md + SKILL-codex.md | merged into one body for every harness; added: spawn step, Message shape, Asks, Artifacts, Proofs, Organizing the work | |
| scripts/peer-chat.py, scripts/peer-chat-paste.py, scripts/peer-chat-spawn.sh, scripts/peer-chat-install.sh | (none) | local; peer-chat.py adapts the engine to pane identity | |

Re-sync: \`bash scripts/sync-upstream.sh\`, then fold \`upstream/*.md\` into the one skill body
and delete \`upstream/\`. \`tests/test-peer-chat-upstream.bats\` fails until the sha256 column
matches the files.
EOF
}

main() {
    command -v gh >/dev/null 2>&1 || {
        echo "sync-upstream: gh not found" >&2
        exit 3
    }
    local sha
    sha="$(resolve_sha)"
    vendor_verbatim
    stage_for_merge
    write_provenance "$sha"
    git -C "$REPO_ROOT" --no-pager diff --stat -- "$PLUGIN_ROOT" tests/fixtures/peer-chat
    echo "sync-upstream: pinned to $sha; merge upstream/SKILL-*.md by hand, then remove upstream/"
}

main "$@"
