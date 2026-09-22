# Upstream

Vendored from https://github.com/umputun/agterm/tree/14858eaeaf0d51ad55e4ba378b8044cae3d0ceff/cookbook/two-agent-chat (MIT).

| local file | upstream file | how | sha256 |
| --- | --- | --- | --- |
| scripts/vendor/peer-chat.py | peer-chat.py | verbatim | 1dc94e1c04a2c4c6a4fca9204d3a0dcf7c5951cf2895c4f9f87f8287e8d03066 |
| tests/fixtures/peer-chat/test_peer_chat.py (repo root) | test_peer_chat.py | verbatim | 0e59f7fc5d52f47a7a246f1a6c41fcab0c3c436e232e764e3a86213007ec18c8 |
| skills/peer-chat/SKILL.md | SKILL-claude.md + SKILL-codex.md | merged into one body for every harness; added: spawn step, Message shape, Asks, Artifacts, Proofs, Organizing the work | |
| scripts/peer-chat.py, scripts/peer-chat-paste.py, scripts/peer-chat-spawn.sh, scripts/peer-chat-install.sh | (none) | local; peer-chat.py adapts the engine to pane identity | |

Re-sync: `bash scripts/sync-upstream.sh`, then fold `upstream/*.md` into the one skill body
and delete `upstream/`. `tests/test-peer-chat-upstream.bats` fails until the sha256 column
matches the files.
