#!/usr/bin/env bash
# sync-upstream — re-vendor the two-agent-chat recipe from umputun/agterm and show what moved.
#
#   sync-upstream.sh [ref]   # default ref: master; prints a diffstat, writes UPSTREAM.md
#
# Vendored verbatim: scripts/peer-chat.py and tests/fixtures/peer-chat/test_peer_chat.py (the test
# lives at the repo root, see CLAUDE.md § Tests). Written to a staging dir for hand-merging:
# codex/SKILL.md and skills/peer-chat/SKILL.md carry local edits (the spawn step, the plugin path),
# so upstream's SKILL-codex.md and SKILL-claude.md land in upstream/ next to them and the diff
# is yours to fold in.
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
	fetch peer-chat.py >"$PLUGIN_ROOT/scripts/peer-chat.py"
	chmod +x "$PLUGIN_ROOT/scripts/peer-chat.py"
	fetch test_peer_chat.py >"$REPO_ROOT/tests/fixtures/peer-chat/test_peer_chat.py"
}

stage_for_merge() {
	mkdir -p "$STAGE"
	fetch SKILL-claude.md >"$STAGE/SKILL-claude.md"
	fetch SKILL-codex.md >"$STAGE/SKILL-codex.md"
	fetch README.md >"$STAGE/README.md"
}

write_provenance() {
	local sha="$1"
	cat >"$PLUGIN_ROOT/UPSTREAM.md" <<EOF
# Upstream

Vendored from https://github.com/$REPO/tree/$sha/$UPSTREAM_DIR (MIT).

| local file | upstream file | how |
| --- | --- | --- |
| scripts/peer-chat.py | peer-chat.py | verbatim |
| tests/fixtures/peer-chat/test_peer_chat.py (repo root) | test_peer_chat.py | verbatim |
| skills/peer-chat/SKILL.md | SKILL-claude.md | edited: spawn step, autonomous trigger, preflight |
| codex/SKILL.md | SKILL-codex.md | edited: the pane may be opened by peer-chat-spawn.sh |
| scripts/peer-chat-spawn.sh, scripts/peer-chat-install.sh | (none) | local |

Re-sync: \`bash scripts/sync-upstream.sh\`, then fold \`upstream/*.md\` into the two edited skills
and delete \`upstream/\`.
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
