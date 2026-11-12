import datetime as dt
import json
from pathlib import Path
import sys


BASE = Path(sys.argv[1])
ROOT = BASE / "acme"
PROJECTS = BASE / "projects"
SLUG = "-Users-test-dev-acme"
NOW = dt.datetime(2026, 11, 11, 10, tzinfo=dt.timezone.utc)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n")


def tool(identity, name, data):
    return {"type": "tool_use", "id": identity, "name": name, "input": data}


def row(kind, content, stamp="2026-11-10T10:00:00Z", **extra):
    return {"type": kind, "timestamp": stamp, "cwd": str(ROOT), "entrypoint": "cli",
            "message": {"content": content}, **extra}


def write_session(name, rows):
    path = PROJECTS / SLUG / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    return path


def first_session():
    skill = tool("skill-one", "Skill", {"skill": "git:commit"})
    command = f'./bin/check && tools/task.py; "{ROOT}/bin/check" | cat docs/guide/a.md docs/README.md'
    command += ' && rg "needle; embedded | pattern" docs/guide; echo "do not split; docker bogus"'
    return [
        row("assistant", [skill]), row("assistant", [skill]),
        row("user", "<command-name>/git:commit</command-name>", uuid="command-one", origin={"kind": "human"}),
        row("assistant", [tool("read-one", "Read", {"file_path": str(ROOT / "docs/guide/index.md")})]),
        row("assistant", [tool("bash-one", "Bash", {"command": command})]),
        row("assistant", [tool("meta", "Skill", {"skill": "skip-meta"})], isMeta=True),
        row("assistant", [tool("side", "Skill", {"skill": "skip-side"})], isSidechain=True),
        row("user", [{"type": "tool_result", "content": "<command-name>/skip-result</command-name>"}]),
    ]


def seed_sessions():
    for number in range(1, 13):
        entrypoint = {2: "sdk-py", 3: "claude-desktop"}.get(number, "cli")
        rows = [row("user", "synthetic task", entrypoint=entrypoint)]
        if number == 1:
            rows += first_session()
        if number <= 3:
            command = "; ".join("docker exec secret-argument" for _ in range(4))
            rows.append(row("assistant", [tool(f"docker-{number}", "Bash", {"command": command})]))
        if number == 4:
            rows.append(row("assistant", [tool("start", "Skill", {"skill": "window:start"})],
                            stamp="2026-11-04T10:00:00Z"))
        path = write_session(f"main-{number:02d}.jsonl", rows)
    with path.open("a") as stream:
        stream.write('{"truncated":\nnull\n[]\n')
    write_session("outside.jsonl", [row("user", "old", stamp="2026-11-04T09:59:59Z"),
                                     row("user", "future", stamp="2026-11-11T10:00:00Z")])
    write_session("main-01/subagents/agent-one.jsonl", [
        row("assistant", [tool("child-skill", "Skill", {"skill": "test:review"}),
                          tool("child-read", "Read", {"file_path": "docs/guide/child.md"}),
                          tool("skill-one", "Skill", {"skill": "git:commit"})], isSidechain=True),
    ])


def seed_project():
    for directory in ("docs/guide", "docs/unused", "bin", "scripts", "tools", ".git", "nested/src"):
        (ROOT / directory).mkdir(parents=True, exist_ok=True)
    write_json(ROOT / ".session-learnings.json", {"knowledge_paths": ["docs/"], "script_dirs": ["bin/"]})
    for name in ("docs/guide/index.md", "docs/guide/a.md", "docs/guide/child.md", "docs/README.md", "tools/task.py"):
        (ROOT / name).write_text("synthetic fixture\n")
    write_json(BASE / "config.json", {"private": "never-record", "skillUsage": {
        "dormant": {"usageCount": 8, "lastUsedAt": int((NOW - dt.timedelta(days=31)).timestamp() * 1000)},
        "recent": {"usageCount": 3, "lastUsedAt": int(NOW.timestamp() * 1000)},
        "boundary": {"usageCount": 1, "lastUsedAt": int((NOW - dt.timedelta(days=30)).timestamp() * 1000)},
        "bad": {"usageCount": True, "lastUsedAt": 1}, "negative": {"usageCount": -1, "lastUsedAt": 1},
    }})


seed_project()
seed_sessions()
