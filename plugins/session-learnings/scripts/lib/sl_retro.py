"""sl-retro: find past Claude and Codex sessions, render them for full reads, gate readers on coverage.

find      JSONL candidate rows from both harnesses and both prompt histories
render    readable, wrapped, redacted parts plus manifest.json
coverage  the exact union of line numbers a reader's Read calls returned, per part
"""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from dataclasses import dataclass, field

UTC = dt.timezone.utc
HEADLESS = {"sdk-cli", "sdk-py", "sdk-ts"}
ID_TERM = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{1,4}){0,4}(?:[0-9a-f-]*)")
SESSION_ID = re.compile(r"[0-9a-f][0-9a-f-]{7,63}")
WINDOW = re.compile(r"(?P<id>[0-9a-f-]+):(?P<start>\d+)-(?P<end>\d*)")
READ_LINE = re.compile(r"^\s*(\d+)\t(.*)$", re.M)
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
SKILL_BODY = "Base directory for this skill"
CODEX_INJECTED = (
    "<environment_context>",
    "# AGENTS.md instructions",
    "<user_instructions>",
    "<permissions instructions>",
)
DEFAULT_PART_LINES = 4000
DEFAULT_WIDTH = 1000
CONTINUATION = "↳ "


class RetroError(ValueError):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise RetroError(message)


@dataclass(frozen=True)
class Homes:
    claude: Path
    codex: Path


@dataclass
class Filters:
    ids: list
    topic: object
    command: object
    since: object
    until: object
    root: object
    exclude: set
    codex: bool


@dataclass
class Candidate:
    harness: str
    session_id: str
    path: object
    project: object = None
    first_ts: object = None
    last_ts: object = None
    bytes: int = 0
    hits: int = 0
    human_hits: int = 0
    first_prompt: object = None
    entrypoint: object = None
    status: str = "ok"
    command_hits: int = 0

    def row(self):
        return {
            "harness": self.harness,
            "session_id": self.session_id,
            "path": str(self.path) if self.path else None,
            "project": self.project,
            "first_ts": self.first_ts,
            "last_ts": self.last_ts,
            "bytes": self.bytes,
            "hits": self.hits,
            "human_hits": self.human_hits,
            "first_prompt": self.first_prompt,
            "entrypoint": self.entrypoint,
            "status": self.status,
        }


@dataclass
class Block:
    lines: list
    source_line: int
    breaks_before: bool = False
    source: str = "main"


@dataclass
class Rendering:
    blocks: list = field(default_factory=list)
    omitted: dict = field(default_factory=dict)
    source: str = "main"

    def omit(self, kind, line):
        self.omitted.setdefault(kind, []).append((self.source, line))

    def add(self, header, body, line, breaks_before=False):
        text = header + ("\n" + body if body else "")
        self.blocks.append(Block(text.split("\n") + [""], line, breaks_before, self.source))


# ---------------------------------------------------------------- config --


def homes():
    claude = Path(
        os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")
    ).expanduser()
    codex = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
    return Homes(claude, codex)


def repo_root(cwd):
    result = subprocess.run(
        ["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    return (
        Path(result.stdout.strip()) if result.returncode == 0 else Path(cwd).resolve()
    )


def load_profile(root):
    path = root / ".session-learnings.json"
    if not (path.exists() or path.is_symlink()):
        return None, {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RetroError(f"cannot read profile {path}: {error}") from error
    if not isinstance(raw, dict):
        raise RetroError(f"cannot read profile {path}: expected a JSON object")
    return path, raw


def part_lines_setting(raw):
    value = raw.get("retro_part_lines")
    if value is None:
        return DEFAULT_PART_LINES, "default"
    if not isinstance(value, int) or value < 50:
        raise RetroError("retro_part_lines must be an integer of at least 50")
    return value, "profile"


def tmp_is_ignored(root):
    probe = subprocess.run(
        ["git", "-C", str(root), "check-ignore", "-q", "tmp/retro"],
        capture_output=True,
        check=False,
    )
    return probe.returncode == 0


def env_source(name):
    return f"detected:{name}" if os.environ.get(name) else "default"


def explain(cwd):
    root = repo_root(cwd)
    profile, raw = load_profile(root)
    part_lines, part_source = part_lines_setting(raw)
    found = homes()
    ignored = tmp_is_ignored(root)
    return {
        "plugin": "session-learnings",
        "profile_file": str(profile) if profile else None,
        "values": {
            "claude_dir": str(found.claude),
            "codex_dir": str(found.codex),
            "scope_root": str(root),
            "out_root": str(root / "tmp" / "retro") if ignored else None,
            "part_lines": part_lines,
            "wrap_width": DEFAULT_WIDTH,
        },
        "sources": {
            "claude_dir": env_source("CLAUDE_CONFIG_DIR"),
            "codex_dir": env_source("CODEX_HOME"),
            "scope_root": "detected:git-toplevel",
            "out_root": "detected:gitignored-tmp" if ignored else "default",
            "part_lines": part_source,
            "wrap_width": "default",
        },
    }


# ------------------------------------------------------------------ rows --


def read_rows(path, limit=None):
    with path.open(encoding="utf-8", errors="replace") as stream:
        for number, line in enumerate(stream, 1):
            if limit is not None and number > limit:
                return
            try:
                row = json.loads(line)
            except ValueError:
                yield number, None, line
                continue
            yield number, row if isinstance(row, dict) else None, line


def timestamp(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        seconds = value / 1000 if value > 1e11 else value
        return dt.datetime.fromtimestamp(seconds, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return str(value)


def day_bound(text, end):
    if text is None:
        return None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        return text + ("T23:59:59Z" if end else "T00:00:00Z")
    return text


def text_of(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = [
        item.get("text", "")
        for item in content
        if isinstance(item, dict)
        and item.get("type") in ("text", "input_text", "output_text")
    ]
    return "\n".join(parts)


def short(text, limit=200):
    flat = " ".join(REMINDER.sub("", text).split())
    return flat[:limit]


# ------------------------------------------------------------------ find --


def is_id_term(term):
    return bool(ID_TERM.fullmatch(term)) and len(term.replace("-", "")) >= 8


def parse_terms(terms):
    ids = [term for term in terms if is_id_term(term)]
    topics = [term for term in terms if not is_id_term(term)]
    if len(topics) > 1:
        raise RetroError("give one topic regex; join alternatives with |")
    try:
        topic = re.compile(topics[0], re.I) if topics else None
    except re.error as error:
        raise RetroError(f"bad topic regex: {error}") from error
    return ids, topic


def command_pattern(name):
    if not name:
        return None
    bare = re.escape(name.lstrip("/"))
    return re.compile(rf"<command-name>/{bare}</command-name>|\"skill\":\s*\"{bare}\"")


def wanted_by_id(session_id, ids):
    return any(session_id.startswith(term) for term in ids)


def scoped(project, root):
    if root is None:
        return True
    return project is not None and (
        project == str(root) or project.startswith(str(root) + "/")
    )


def within(candidate, filters):
    if filters.since and (candidate.last_ts or "") < filters.since:
        return False
    return not (filters.until and (candidate.first_ts or "9") > filters.until)


def claude_transcripts(home):
    projects = home.claude / "projects"
    if not projects.is_dir():
        return []
    return sorted(p for p in projects.glob("*/*.jsonl") if p.is_file())


def subagent_files(transcript):
    directory = transcript.with_suffix("") / "subagents"
    return sorted(directory.glob("agent-*.jsonl")) if directory.is_dir() else []


def scan_claude(path, filters):
    candidate = Candidate("claude", path.stem, path)
    candidate.bytes = path.stat().st_size + sum(
        p.stat().st_size for p in subagent_files(path)
    )
    for _, row, raw in read_rows(path):
        observe_claude_row(candidate, row, raw, filters)
    return candidate


def observe_claude_row(candidate, row, raw, filters):
    if row is None:
        candidate.status = "partial"
        return
    stamp = row.get("timestamp")
    if stamp:
        candidate.first_ts = candidate.first_ts or stamp
        candidate.last_ts = stamp
    candidate.project = candidate.project or row.get("cwd")
    candidate.entrypoint = candidate.entrypoint or row.get("entrypoint")
    human = claude_human_text(row)
    if human is not None and candidate.first_prompt is None:
        candidate.first_prompt = short(human)
    count_hits(candidate, raw, human, filters)


def claude_human_text(row):
    if (
        row.get("type") == "attachment"
        and (row.get("attachment") or {}).get("type") == "queued_command"
    ):
        return str(row["attachment"].get("prompt", ""))
    if row.get("type") != "user" or (row.get("origin") or {}).get("kind") != "human":
        return None
    return text_of((row.get("message") or {}).get("content"))


def count_hits(candidate, raw, human, filters):
    if filters.command and filters.command.search(raw):
        candidate.command_hits += 1
    if not filters.topic:
        return
    if filters.topic.search(raw):
        candidate.hits += 1
    if human is not None and filters.topic.search(human):
        candidate.human_hits += 1


def codex_rollouts(home):
    sessions = home.codex / "sessions"
    if not sessions.is_dir():
        return []
    return sorted(p for p in sessions.glob("*/*/*/rollout-*.jsonl") if p.is_file())


def scan_codex(path, filters):
    candidate = Candidate("codex", codex_id(path), path)
    candidate.bytes = path.stat().st_size
    for _, row, raw in read_rows(path):
        observe_codex_row(candidate, row, raw, filters)
    return candidate


def codex_id(path):
    match = re.search(
        r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$",
        path.name,
    )
    return match.group(1) if match else path.stem


def observe_codex_row(candidate, row, raw, filters):
    if row is None:
        candidate.status = "partial"
        return
    stamp = row.get("timestamp")
    if stamp:
        candidate.first_ts = candidate.first_ts or stamp
        candidate.last_ts = stamp
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    if row.get("type") == "session_meta":
        apply_codex_meta(candidate, payload)
    human = codex_human_text(row, payload)
    if human is not None and candidate.first_prompt is None:
        candidate.first_prompt = short(human)
    count_hits(candidate, raw, human, filters)


def apply_codex_meta(candidate, payload):
    candidate.session_id = payload.get("id") or candidate.session_id
    candidate.project = payload.get("cwd")
    source = payload.get("source")
    candidate.entrypoint = source if isinstance(source, str) else "subagent"


def codex_human_text(row, payload):
    if (
        row.get("type") != "response_item"
        or payload.get("type") != "message"
        or payload.get("role") != "user"
    ):
        return None
    text = text_of(payload.get("content"))
    return None if text.lstrip().startswith(CODEX_INJECTED) else text


def interactive(candidate):
    if candidate.harness == "codex":
        return candidate.entrypoint in ("cli", "vscode")
    return candidate.entrypoint not in HEADLESS


def admit(candidate, filters):
    explicit = wanted_by_id(candidate.session_id, filters.ids)
    if candidate.session_id in filters.exclude:
        return False
    if explicit:
        return True
    if filters.ids and not filters.topic and not filters.command:
        return False
    return (
        interactive(candidate)
        and scoped(candidate.project, filters.root)
        and within(candidate, filters)
        and matches(candidate, filters)
    )


def matches(candidate, filters):
    if filters.command and candidate.command_hits == 0:
        return False
    return not (filters.topic and candidate.hits == 0)


def recent_enough(path, filters):
    if not filters.since or filters.ids:
        return True
    modified = dt.datetime.fromtimestamp(path.stat().st_mtime, UTC).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    return modified >= filters.since


def history_rows(path, harness):
    if not path.is_file():
        return
    for _, row, _ in read_rows(path):
        if row is None:
            continue
        if harness == "claude":
            yield (
                row.get("sessionId"),
                row.get("display", ""),
                timestamp(row.get("timestamp")),
                row.get("project"),
            )
            continue
        yield row.get("session_id"), row.get("text", ""), timestamp(row.get("ts")), None


def pruned_candidates(home, harness, known, filters):
    path = (
        home.claude / "history.jsonl"
        if harness == "claude"
        else home.codex / "history.jsonl"
    )
    pruned = {}
    for session_id, text, stamp, project in history_rows(path, harness) or ():
        if not session_id or (harness, session_id) in known:
            continue
        entry = pruned.setdefault(
            session_id,
            Candidate(harness, session_id, None, project=project, status="pruned"),
        )
        absorb_history(entry, str(text), stamp, filters)
    return [c for c in pruned.values() if admit_pruned(c, filters)]


def absorb_history(entry, text, stamp, filters):
    entry.first_ts = min(filter(None, (entry.first_ts, stamp)), default=None)
    entry.last_ts = max(filter(None, (entry.last_ts, stamp)), default=None)
    entry.first_prompt = entry.first_prompt or short(text)
    if filters.topic and filters.topic.search(text):
        entry.hits += 1
        entry.human_hits += 1
    if filters.command and filters.command.search(
        f"<command-name>{text.split(' ')[0]}</command-name>"
    ):
        entry.command_hits += 1


def admit_pruned(candidate, filters):
    if candidate.session_id in filters.exclude:
        return False
    if wanted_by_id(candidate.session_id, filters.ids):
        return True
    if filters.ids and not filters.topic and not filters.command:
        return False
    unknown_scope = candidate.project is None and filters.root is not None
    return (
        (unknown_scope or scoped(candidate.project, filters.root))
        and within(candidate, filters)
        and matches(candidate, filters)
    )


def classify(candidate):
    if candidate.status == "ok" and candidate.project is None:
        candidate.status = "unclassified"
    return candidate


def dedupe(candidates):
    best = {}
    for candidate in candidates:
        key = (candidate.harness, candidate.session_id)
        if key not in best or candidate.bytes > best[key].bytes:
            best[key] = candidate
    return sorted(
        best.values(), key=lambda c: (c.first_ts or "", c.harness, c.session_id)
    )


def find(filters, home):
    scanned = scan_all(home, filters)
    known = {(c.harness, c.session_id) for c in scanned}
    admitted = [classify(c) for c in scanned if admit(c, filters)]
    admitted += pruned_candidates(home, "claude", known, filters)
    if filters.codex:
        admitted += pruned_candidates(home, "codex", known, filters)
    return [settle_hits(c, filters) for c in dedupe(admitted)]


def settle_hits(candidate, filters):
    if not filters.topic:
        candidate.hits = candidate.command_hits
    return candidate


def scan_all(home, filters):
    found = [
        scan_claude(p, filters)
        for p in claude_transcripts(home)
        if recent_enough(p, filters)
    ]
    if filters.codex:
        found += [
            scan_codex(p, filters)
            for p in codex_rollouts(home)
            if recent_enough(p, filters)
        ]
    return found


def build_filters(args):
    ids, topic = parse_terms(args.terms)
    if not ids and not topic and not args.command:
        raise RetroError("find needs a topic regex, --command or session ids")
    root = (
        None
        if args.all_projects
        else Path(args.project).resolve() if args.project else repo_root(Path.cwd())
    )
    exclude = set(args.exclude_session or [])
    caller = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if caller and not args.include_caller:
        exclude.add(caller)
    return Filters(
        ids,
        topic,
        command_pattern(args.command),
        day_bound(args.since, False),
        day_bound(args.until, True),
        root,
        exclude,
        args.codex or bool(ids),
    )


# ---------------------------------------------------------------- render --


def wrap(line, width):
    if len(line) <= width:
        return [line]
    step = width - len(CONTINUATION)
    head, rest = line[:width], line[width:]
    return [head] + [
        CONTINUATION + rest[i : i + step] for i in range(0, len(rest), step)
    ]


def strip_reminders(text, rendering, line):
    found = REMINDER.findall(text)
    for _ in found:
        rendering.omit("system-reminder", line)
    return REMINDER.sub("", text).strip()


def in_window(number, window):
    start, end = window
    return number >= start and (end is None or number <= end)


def render_claude(path, window, agent_marks, mark):
    rendering = Rendering()
    spawned = {}
    for number, row, _ in read_rows(path, mark["lines"]):
        if in_window(number, window):
            render_claude_row(rendering, row, number, "L", spawned)
    cutoffs = mark.get("agents", {})
    agents = sorted((a for a in subagent_files(path) if a.stem in cutoffs), key=lambda a: spawn_line(a, spawned))
    for agent in agents:
        if wants_agent(agent, spawned, window, agent_marks, cutoffs[agent.stem]):
            first = (agent_marks or {}).get(agent.stem, 0) + 1
            render_subagent(rendering, agent, spawned, first, cutoffs[agent.stem])
    return rendering


def wants_agent(agent, spawned, window, agent_marks, cutoff):
    if agent_marks is not None:
        return cutoff > agent_marks.get(agent.stem, 0)
    if window == (1, None):
        return True
    return read_meta(agent).get("toolUseId") in spawned


def spawn_line(agent, spawned):
    return spawned.get(read_meta(agent).get("toolUseId"), float("inf")), agent.name


def render_subagent(rendering, agent, spawned, first_line, cutoff):
    meta = read_meta(agent)
    spawn = spawned.get(meta.get("toolUseId"), "?")
    resumed = f" from S{first_line}" if first_line > 1 else ""
    rendering.source = agent.stem
    rendering.add(f'### SUBAGENT {agent.stem} "{meta.get("description", "")}" spawned at L{spawn}{resumed}', "", 0)
    for number, row, _ in read_rows(agent, cutoff):
        if number >= first_line:
            render_claude_row(rendering, row, number, "S", {})
    rendering.source = "main"


def read_meta(agent):
    meta = agent.with_suffix(".meta.json")
    try:
        return json.loads(meta.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def render_claude_row(rendering, row, number, prefix, spawned):
    if row is None:
        rendering.omit("unparseable", number)
        return
    kind = row.get("type")
    if kind == "system" and row.get("subtype") == "compact_boundary":
        rendering.add(
            f"=== COMPACTION {prefix}{number} {row.get('timestamp', '')}",
            "",
            number,
            breaks_before=True,
        )
        return
    if kind == "attachment":
        render_attachment(rendering, row, number, prefix)
        return
    if kind == "user":
        render_user(rendering, row, number, prefix)
        return
    if kind == "assistant":
        render_assistant(rendering, row, number, prefix, spawned)
        return
    label = f"system:{row.get('subtype')}" if kind == "system" else f"row:{kind}"
    rendering.omit(label, number)


def render_attachment(rendering, row, number, prefix):
    attachment = row.get("attachment") or {}
    if attachment.get("type") != "queued_command":
        rendering.omit(f"attachment:{attachment.get('type')}", number)
        return
    rendering.add(
        f"### USER (queued) {stamp_of(row)} {prefix}{number}",
        str(attachment.get("prompt", "")),
        number,
    )


def stamp_of(row):
    return str(row.get("timestamp", ""))[:19]


def render_user(rendering, row, number, prefix):
    if row.get("isMeta") is True:
        rendering.omit("meta", number)
        return
    content = (row.get("message") or {}).get("content")
    who = "USER" if (row.get("origin") or {}).get("kind") == "human" else "INPUT"
    if row.get("isCompactSummary"):
        who = "COMPACT SUMMARY"
    items = (
        [{"type": "text", "text": content}]
        if isinstance(content, str)
        else content or []
    )
    for item in items:
        render_user_item(rendering, item, row, number, prefix, who)


def render_user_item(rendering, item, row, number, prefix, who):
    if not isinstance(item, dict):
        return
    if item.get("type") == "tool_result":
        status = "error" if item.get("is_error") else "ok"
        body = tool_result_text(item.get("content"))
        rendering.add(
            f"  <- result {status} {prefix}{number} {item.get('tool_use_id', '')}",
            body,
            number,
        )
        return
    if item.get("type") != "text":
        rendering.omit(f"user:{item.get('type')}", number)
        return
    render_user_text(rendering, item.get("text", ""), row, number, prefix, who)


def render_user_text(rendering, text, row, number, prefix, who):
    if text.startswith(SKILL_BODY):
        rendering.omit("skill-body", number)
        return
    kept = strip_reminders(text, rendering, number)
    if kept:
        rendering.add(f"### {who} {stamp_of(row)} {prefix}{number}", kept, number)


def tool_result_text(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(
        item.get("text", "") if item.get("type") == "text" else f"[{item.get('type')}]"
        for item in content
        if isinstance(item, dict)
    )


def render_assistant(rendering, row, number, prefix, spawned):
    for item in (row.get("message") or {}).get("content") or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            rendering.add(
                f"### CLAUDE {stamp_of(row)} {prefix}{number}",
                item.get("text", ""),
                number,
            )
            continue
        if item.get("type") == "tool_use":
            (
                spawned.setdefault(item.get("id"), number)
                if item.get("name")
                in (
                    "Agent",
                    "Task",
                )
                else None
            )
            rendering.add(
                f"  -> {item.get('name')} {prefix}{number} {item.get('id', '')}",
                json.dumps(item.get("input"), ensure_ascii=False),
                number,
            )
            continue
        rendering.omit(f"assistant:{item.get('type')}", number)


def render_codex(path, window, mark):
    rendering = Rendering()
    for number, row, _ in read_rows(path, mark["lines"]):
        if in_window(number, window):
            render_codex_row(rendering, row, number)
    return rendering


def render_codex_row(rendering, row, number):
    if row is None:
        rendering.omit("unparseable", number)
        return
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    if row.get("type") == "compacted":
        rendering.add(
            f"=== COMPACTION L{number} {row.get('timestamp', '')}",
            "",
            number,
            breaks_before=True,
        )
        return
    if row.get("type") != "response_item":
        rendering.omit(f"row:{row.get('type')}", number)
        return
    render_codex_item(rendering, payload, row, number)


def render_codex_item(rendering, payload, row, number):
    kind = payload.get("type")
    stamp = stamp_of(row)
    if kind == "message":
        render_codex_message(rendering, payload, stamp, number)
        return
    if kind in ("function_call", "custom_tool_call"):
        body = (
            payload.get("arguments")
            if kind == "function_call"
            else payload.get("input")
        )
        rendering.add(
            f"  -> {payload.get('name')} L{number} {payload.get('call_id', '')}",
            str(body or ""),
            number,
        )
        return
    if kind in ("function_call_output", "custom_tool_call_output"):
        rendering.add(
            f"  <- result L{number} {payload.get('call_id', '')}",
            codex_output(payload.get("output")),
            number,
        )
        return
    rendering.omit(f"codex:{kind}", number)


def render_codex_message(rendering, payload, stamp, number):
    role = payload.get("role")
    text = text_of(payload.get("content"))
    if role == "developer" or text.lstrip().startswith(CODEX_INJECTED):
        rendering.omit("codex:injected-context", number)
        return
    label = "USER" if role == "user" else "CODEX"
    rendering.add(f"### {label} {stamp} L{number}", text, number)


def codex_output(output):
    if isinstance(output, str):
        return output
    if isinstance(output, list):
        return text_of(output)
    return json.dumps(output, ensure_ascii=False)


def split_parts(rendering, limit, width):
    parts, current, lines_seen = [], [], []
    for block in rendering.blocks:
        wrapped = [piece for line in block.lines for piece in wrap(line, width)]
        if current and (block.breaks_before or len(current) + len(wrapped) > limit):
            parts.append((current, lines_seen))
            current, lines_seen = [], []
        lines_seen.append((block.source, block.source_line))
        current, parts = spill(current + wrapped, parts, limit, lines_seen)
    if current:
        parts.append((current, lines_seen))
    return parts


def spill(lines, parts, limit, lines_seen):
    while len(lines) > limit:
        parts.append((lines[:limit], list(lines_seen)))
        lines = lines[limit:]
    return lines, parts


def redact(text, *flags):
    script = Path(__file__).resolve().parent.parent / "sl-redact.sh"
    result = subprocess.run(
        [str(script), *flags], input=text, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise RetroError(f"sl-redact.sh failed: {result.stderr.strip()}")
    return result.stdout


def redact_previews(candidates):
    stream = "".join(json.dumps(c.first_prompt) + "\n" for c in candidates)
    previews = [json.loads(line) for line in redact(stream, "--jsonl").splitlines()] if candidates else []
    if len(previews) != len(candidates):
        raise RetroError("redaction changed the preview count; refusing to print")
    for candidate, preview in zip(candidates, previews):
        candidate.first_prompt = preview
    return candidates


def part_ranges(parts):
    spans = [source_spans(seen) for _, seen in parts]
    last = {source: index for index, span in enumerate(spans) for source in span}
    reached, ranges = {}, []
    for index, span in enumerate(spans):
        ranges.append({source: (reached.get(source, 0) + 1, math.inf if last[source] == index else high)
                       for source, (_, high) in span.items()})
        reached.update({source: high for source, (_, high) in span.items()})
    return ranges


def source_spans(seen):
    spans = {}
    for source, line in seen:
        if line > 0:
            low, high = spans.get(source, (line, line))
            spans[source] = (min(low, line), max(high, line))
    return spans


def omitted_for(rendering, ranges):
    kept = []
    for kind, entries in sorted(rendering.omitted.items()):
        for source in sorted({source for source, _ in entries}):
            inside = [n for s, n in entries if s == source and source in ranges and ranges[source][0] <= n <= ranges[source][1]]
            if inside:
                kept.append({"kind": kind, "source": source, "count": len(inside), "source_lines": inside})
    return kept


def high_water(path):
    lines, size = complete_records(path)
    mark = {"lines": lines, "bytes": size}
    agents = subagent_files(path) if path.suffix == ".jsonl" and path.with_suffix("").is_dir() else []
    if agents:
        mark["agents"] = {agent.stem: complete_records(agent)[0] for agent in agents}
    return mark


def complete_records(path):
    lines = size = 0
    with path.open("rb") as stream:
        for line in stream:
            if not line.endswith(b"\n"):
                break
            lines, size = lines + 1, size + len(line)
    return lines, size


def write_parts(target, out_dir, limit, width):
    mark = high_water(target.path)
    rendering = (
        render_claude(target.path, target.window, target.agent_marks, mark)
        if target.harness == "claude"
        else render_codex(target.path, target.window, mark)
    )
    sessions = out_dir / "sessions"
    sessions.mkdir(parents=True, exist_ok=True)
    redact_blocks(rendering)
    parts = split_parts(rendering, limit, width)
    stem = part_stem(target)
    return [
        write_part(sessions / f"{stem}-p{index:02d}.txt", lines, omitted_for(rendering, span), target, mark)
        for index, ((lines, _), span) in enumerate(zip(parts, part_ranges(parts)), 1)
    ]


def part_stem(target):
    base = f"{target.harness}-{target.session_id}"
    if target.delta:
        return f"{base}-d{target.window[0]}-{sum((target.agent_marks or {}).values())}"
    start, end = target.window
    return base if (start, end) == (1, None) else f"{base}-w{start}-{end or 'end'}"


def redact_blocks(rendering):
    separator = "\x1e"
    joined = separator.join("\n".join(block.lines) for block in rendering.blocks)
    scrubbed = redact(joined).split(separator)
    if len(scrubbed) != len(rendering.blocks):
        raise RetroError("redaction changed the block structure; refusing to write parts")
    for block, text in zip(rendering.blocks, scrubbed):
        block.lines = text.split("\n")


def write_part(path, lines, omitted, target, mark):
    refuse_symlink(path.parent)
    refuse_symlink(path)
    if path.parent.resolve() != path.resolve().parent or path.name != Path(path.name).name:
        raise RetroError(f"part path escapes its sessions directory: {path}")
    text = "\n".join(lines) + "\n"
    path.write_text(text, encoding="utf-8")
    return {
        "file": str(path.resolve()),
        "lines": text.count("\n"),
        "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "omitted": omitted,
        "source": {
            "harness": target.harness,
            "session_id": target.session_id,
            "path": str(target.path),
            "from_line": target.window[0],
            "to_line": target.window[1],
        },
        "high_water": mark,
    }


def verified_text(part):
    path = Path(part["file"])
    try:
        data = path.read_bytes()
    except OSError as error:
        raise RetroError(f"cannot read part {path}: {error.strerror}") from error
    if hashlib.sha256(data).hexdigest() != part["sha256"]:
        raise RetroError(f"part changed since the manifest (sha256 mismatch): {path}")
    return data.decode("utf-8", errors="replace").split("\n")


@dataclass
class Target:
    harness: str
    session_id: str
    path: Path
    window: tuple
    delta: bool = False
    agent_marks: object = None


def targets_from_rows(rows):
    targets = []
    for row in rows:
        if not row.get("path"):
            print(f"session-learnings: skipped {row.get('session_id')}: status {row.get('status')}, no transcript", file=sys.stderr)
            continue
        start, end = row.get("window") or (1, None)
        window = (int(start), int(end) if end is not None else None)
        targets.append(Target(checked_harness(row), checked_session(row), checked_source(row), window))
    return targets


def checked_harness(row):
    harness = row.get("harness")
    if harness not in ("claude", "codex"):
        raise RetroError(f"harness must be claude or codex, got {harness!r}")
    return harness


def checked_session(row):
    session = str(row.get("session_id", ""))
    if not SESSION_ID.fullmatch(session):
        raise RetroError(f"session_id must be hex digits and dashes, got {session!r}")
    return session


def checked_source(row):
    path = Path(row["path"]).expanduser()
    if not path.is_file() or path.suffix != ".jsonl":
        raise RetroError(f"source transcript is not a .jsonl file: {path}")
    return path


def targets_from_terms(terms, home):
    rows = []
    for term in terms:
        match = WINDOW.fullmatch(term)
        session = match.group("id") if match else term
        window = (
            (
                int(match.group("start")),
                int(match.group("end")) if match.group("end") else None,
            )
            if match
            else (1, None)
        )
        rows.append(locate(session, home) | {"window": window})
    return targets_from_rows(rows)


def locate(session, home):
    for path in claude_transcripts(home):
        if path.stem.startswith(session):
            return {"harness": "claude", "session_id": path.stem, "path": str(path)}
    for path in codex_rollouts(home):
        if codex_id(path).startswith(session):
            return {"harness": "codex", "session_id": codex_id(path), "path": str(path)}
    raise RetroError(f"no transcript for session {session}")


def stdin_rows():
    rows = []
    for line in sys.stdin:
        if line.strip():
            rows.append(json.loads(line))
    return rows


def manifest_path(out_dir):
    return out_dir / "manifest.json"


def load_manifest(out_dir):
    path = manifest_path(out_dir)
    if not path.is_file():
        return {"parts": []}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError as error:
        raise RetroError(f"cannot read {path}: {error}") from error


def save_manifest(out_dir, manifest):
    path = manifest_path(out_dir)
    scratch = path.with_suffix(".tmp")
    refuse_symlink(path)
    refuse_symlink(scratch)
    scratch.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    scratch.replace(path)


def refuse_symlink(path):
    if path.is_symlink():
        raise RetroError(f"refusing to write through a symlink: {path}")


def merge_parts(manifest, new_parts, replace):
    keys = {
        (p["source"]["path"], p["source"]["from_line"], p["source"]["to_line"])
        for p in new_parts
    }
    kept = [p for p in manifest["parts"] if not replace or source_key(p) not in keys]
    return {**manifest, "parts": kept + new_parts}


def source_key(part):
    return (
        part["source"]["path"],
        part["source"]["from_line"],
        part["source"]["to_line"],
    )


def delta_targets(manifest):
    sources = [part["source"] for part in manifest["parts"] if part["source"].get("to_line") is None]
    for source in sources:
        checked_harness(source)
        checked_session(source)
    unique = {source["path"]: source for source in sources}
    return [target for target in (grown(manifest, s) for s in unique.values()) if target]


def grown(manifest, source):
    path = Path(source["path"])
    if not path.is_file():
        return None
    harness, session, path = checked_harness(source), checked_session(source), checked_source(source)
    seen = latest_mark(manifest, source["path"])
    current = high_water(path)
    agents_seen = seen.get("agents", {})
    agents_grew = any(lines > agents_seen.get(stem, 0) for stem, lines in current.get("agents", {}).items())
    if current["lines"] <= seen["lines"] and not agents_grew:
        return None
    return Target(harness, session, path, (seen["lines"] + 1, None), True, agents_seen)


def latest_mark(manifest, key):
    marks = [p["high_water"] for p in manifest["parts"] if p["source"]["path"] == key]
    agents = {}
    for mark in marks:
        for stem, lines in mark.get("agents", {}).items():
            agents[stem] = max(agents.get(stem, 0), lines)
    return {"lines": max(m["lines"] for m in marks), "agents": agents}


def reader_transcripts(args, home):
    paths = [Path(t) for t in args.transcript or []]
    paths += [subagent_transcript(agent, args.parent, home) for agent in args.agent or []]
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        raise RetroError(f"reader transcript not found: {', '.join(missing)}")
    return paths


def subagent_transcript(agent, parent, home):
    matches = sorted((home.claude / "projects").glob(f"*/{parent}*/subagents/agent-{agent}.jsonl"))
    if not matches:
        raise RetroError(f"no subagent transcript agent-{agent} under session {parent}")
    return matches[0]


def out_dir_for(args):
    if args.out:
        return Path(args.out).expanduser().resolve() / args.slug
    root = repo_root(Path.cwd())
    if tmp_is_ignored(root):
        return root / "tmp" / "retro" / args.slug
    raise RetroError(
        "tmp/retro is not git-ignored here; pass --out <dir> (for example a mktemp -d directory)"
    )


def render(args, home):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", args.slug):
        raise RetroError("--slug must be lowercase letters, digits and dashes")
    out_dir = out_dir_for(args)
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest(out_dir)
    targets = (
        delta_targets(manifest)
        if args.delta
        else (
            targets_from_terms(args.terms, home)
            if args.terms
            else targets_from_rows(stdin_rows())
        )
    )
    new_parts = [
        part
        for target in targets
        for part in write_parts(target, out_dir, args.part_lines, args.width)
    ]
    save_manifest(
        out_dir, merge_parts({**manifest, "slug": args.slug}, new_parts, not args.delta)
    )
    for part in new_parts:
        print(
            json.dumps(
                {k: part[k] for k in ("file", "lines", "sha256", "source")},
                ensure_ascii=False,
            )
        )


# -------------------------------------------------------------- coverage --


def read_calls(paths):
    returned = {}
    for path in paths:
        calls = {}
        for _, row, _ in read_rows(path):
            if row is not None:
                collect_calls(row, calls)
                collect_results(row, calls, returned)
    return returned


def collect_calls(row, calls):
    if row.get("type") != "assistant":
        return
    for item in (row.get("message") or {}).get("content") or []:
        if (
            isinstance(item, dict)
            and item.get("type") == "tool_use"
            and item.get("name") == "Read"
        ):
            calls[item.get("id")] = str(
                Path((item.get("input") or {}).get("file_path", "")).resolve()
            )


def collect_results(row, calls, returned):
    content = (row.get("message") or {}).get("content")
    if row.get("type") != "user" or not isinstance(content, list):
        return
    for item in content:
        if not isinstance(item, dict) or item.get("type") != "tool_result" or item.get("is_error"):
            continue
        target = calls.get(item.get("tool_use_id"))
        if target:
            lines = returned.setdefault(target, {})
            for number, text in READ_LINE.findall(tool_result_text(item.get("content"))):
                lines.setdefault(int(number), set()).add(text)


def ranges(missing):
    spans, start, previous = [], None, None
    for number in missing:
        if start is None:
            start = previous = number
            continue
        if number == previous + 1:
            previous = number
            continue
        spans.append([start, previous])
        start = previous = number
    if start is not None:
        spans.append([start, previous])
    return spans


def assigned_parts(manifest, files):
    parts = manifest["parts"]
    if not files:
        return parts
    wanted = {str(Path(f).resolve()) for f in files}
    chosen = [p for p in parts if str(Path(p["file"]).resolve()) in wanted]
    unknown = wanted - {str(Path(p["file"]).resolve()) for p in chosen}
    if unknown:
        raise RetroError(f"not in the manifest: {', '.join(sorted(unknown))}")
    return chosen


def coverage_row(part, returned, current):
    got = returned.get(str(Path(part["file"]).resolve()), {})
    total = part["lines"]
    seen = {n for n in range(1, total + 1) if n <= len(current) and current[n - 1] in got.get(n, ())}
    missing = [n for n in range(1, total + 1) if n not in seen]
    return {"file": part["file"], "lines": total, "covered": len(seen), "missing_ranges": ranges(missing), "ok": not missing}


def coverage(args, home):
    manifest_file = Path(args.manifest)
    if not manifest_file.is_file():
        raise RetroError(f"manifest not found: {manifest_file}")
    manifest = load_manifest(manifest_file.parent) if manifest_file.name == "manifest.json" else json.loads(manifest_file.read_text(encoding="utf-8"))
    parts = assigned_parts(manifest, args.files)
    if not parts:
        raise RetroError(f"no parts to check in {manifest_file}")
    texts = [verified_text(part) for part in parts]
    returned = read_calls(reader_transcripts(args, home))
    rows = [coverage_row(part, returned, text) for part, text in zip(parts, texts)]
    for row in rows:
        print(json.dumps(row, ensure_ascii=False))
    return 0 if all(row["ok"] for row in rows) else 1


# ------------------------------------------------------------------- cli --


def parser():
    root = Parser(prog="sl-retro.sh", allow_abbrev=False)
    root.add_argument("--explain", action="store_true")
    verbs = root.add_subparsers(dest="verb", parser_class=Parser)
    add_find(verbs.add_parser("find"))
    add_render(verbs.add_parser("render"))
    add_coverage(verbs.add_parser("coverage"))
    return root


def add_find(sub):
    sub.add_argument("terms", nargs="*")
    sub.add_argument("--since")
    sub.add_argument("--until")
    sub.add_argument("--command")
    sub.add_argument("--codex", action="store_true")
    sub.add_argument("--all-projects", action="store_true")
    sub.add_argument("--project")
    sub.add_argument("--exclude-session", action="append")
    sub.add_argument("--include-caller", action="store_true")


def add_render(sub):
    sub.add_argument("terms", nargs="*")
    sub.add_argument("--slug", required=True)
    sub.add_argument("--out")
    sub.add_argument("--delta", action="store_true")
    sub.add_argument("--part-lines", type=int)
    sub.add_argument("--width", type=int, default=DEFAULT_WIDTH)


def add_coverage(sub):
    sub.add_argument("--manifest", required=True)
    sub.add_argument("--transcript", action="append")
    sub.add_argument("--agent", action="append")
    sub.add_argument("--parent")
    sub.add_argument("--files", nargs="+")


def resolve_render_settings(args):
    if args.part_lines is None:
        _, raw = load_profile(repo_root(Path.cwd()))
        args.part_lines, _ = part_lines_setting(raw)
    if args.part_lines < 50 or args.width < 80:
        raise RetroError("--part-lines must be at least 50 and --width at least 80")


def run(args):
    home = homes()
    if args.explain:
        print(json.dumps(explain(Path.cwd())))
        return 0
    if args.verb == "find":
        for candidate in redact_previews(find(build_filters(args), home)):
            print(json.dumps(candidate.row(), ensure_ascii=False))
        return 0
    if args.verb == "render":
        resolve_render_settings(args)
        render(args, home)
        return 0
    if args.verb == "coverage":
        if not args.transcript and not (args.agent and args.parent):
            raise RetroError("coverage needs --transcript or --agent with --parent")
        return coverage(args, home)
    raise RetroError("choose find, render, coverage or --explain")


def main(argv):
    try:
        return run(parser().parse_args(argv))
    except RetroError as error:
        print("session-learnings: " + str(error), file=sys.stderr)
        return error.code
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
