# Upstream

Vendored from https://github.com/umputun/agterm/tree/14858eaeaf0d51ad55e4ba378b8044cae3d0ceff/cookbook/two-agent-chat (MIT).

| local file | upstream file | how |
| --- | --- | --- |
| scripts/peer-chat.py | peer-chat.py | verbatim |
| tests/fixtures/peer-chat/test_peer_chat.py (repo root) | test_peer_chat.py | verbatim |
| skills/peer-chat/SKILL.md | SKILL-claude.md | edited: spawn step, autonomous trigger, preflight |
| codex/SKILL.md | SKILL-codex.md | edited: the pane may be opened by peer-chat-spawn.sh |
| scripts/peer-chat-spawn.sh, scripts/peer-chat-install.sh | (none) | local |

Re-sync: `bash scripts/sync-upstream.sh`, then fold `upstream/*.md` into the two edited skills
and delete `upstream/`.
