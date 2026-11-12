import argparse
import collections
import datetime as dt
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass, field


UTC = dt.timezone.utc
INTERACTIVE = {"cli", "claude-desktop"}
READERS = {"rg", "grep", "sed", "cat", "head", "ls", "find"}
IGNORED = READERS | {
    "cd", "tail", "wc", "jq", "echo", "printf", "git", "mkdir", "trash", "test", "true", "sleep",
    "awk", "cut", "sort", "uniq", "tee", "tr", "xargs", "date", "diff", "comm", "basename", "dirname",
    "realpath", "stat", "which", "command", "type", "env", "export", "source", ".", "set", "unset",
    "read", "local", "return", "exit", "break", "continue", "[", "[[", "false",
}
SCRIPT_SUFFIXES = {".sh", ".py", ".mjs", ".ts"}
DECISIONS = {"accepted", "rejected", "deferred"}
COMMAND = re.compile(r"<command-name>/([^<]+)</command-name>")
REPORT_NAME = re.compile(r"\d{4}-W\d{2}\.json")
SAFE_SECOND = re.compile(r"-{0,2}[A-Za-z][A-Za-z0-9_-]*")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
SHELL_WORDS = {"do", "done", "then", "else", "elif", "fi", "esac", "while", "until", "if", "in", "{", "}", "!"}
DECLARATIONS = {"for", "case", "select", "function"}
INTERPRETERS = {"bash", "sh", "zsh", "python", "python3", "node", "bun", "uvx"}
OPERATORS = re.compile(r"&>>|<<-|<<<|;;&|&&|\|\||\|&|;;|;&|>>|<<|>&|<&|&>|[|;&<>()\n]")


class StatsError(ValueError):
    def __init__(self, message, code=64):
        super().__init__(message)
        self.code = code


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise StatsError(message)


@dataclass(frozen=True)
class Profile:
    root: Path
    file: object
    knowledge: tuple
    scripts: tuple
    sources: dict


@dataclass(frozen=True)
class ShellToken:
    text: str
    operator: bool = False


@dataclass
class Counts:
    totals: collections.Counter = field(default_factory=collections.Counter)
    sessions: dict = field(default_factory=lambda: collections.defaultdict(set))

    def add(self, name, session):
        self.totals[name] += 1
        self.sessions[name].add(session)

    def rows(self, name_key, count_key):
        return [
            {name_key: name, count_key: count, "sessions": len(self.sessions[name])}
            for name, count in sorted(self.totals.items(), key=lambda row: (-row[1], row[0]))
        ]


@dataclass
class Project:
    slug: str
    profile: Profile
    sessions: set = field(default_factory=set)
    scripts: Counts = field(default_factory=Counts)
    hand_rolled: Counts = field(default_factory=Counts)
    knowledge: Counts = field(default_factory=Counts)
    areas: dict = field(default_factory=lambda: collections.defaultdict(collections.Counter))


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp requires a timezone")
    return parsed.astimezone(UTC)


def iso(moment):
    return moment.isoformat().replace("+00:00", "Z")


def week(moment):
    year, number, _ = moment.isocalendar()
    return f"{year}-W{number:02d}"


def read_object(path):
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def project_root(cwd):
    directory = Path(cwd).expanduser().resolve()
    ancestors = (directory, *directory.parents)
    for parent in ancestors:
        profile = parent / ".session-learnings.json"
        if profile.exists() or profile.is_symlink():
            return parent
    return next((p for p in ancestors if (p / ".git").exists()), directory)


def profile_paths(value, key):
    if not isinstance(value, list) or any(not isinstance(p, str) or not p.strip() for p in value):
        raise StatsError(f"{key} must be an array of relative directory paths", 2)
    paths = []
    for raw in value:
        path = Path(raw)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise StatsError(f"{key} must stay below the project root", 2)
        paths.append(path.as_posix().rstrip("/") + "/")
    return tuple(dict.fromkeys(paths))


def profile_value(raw, root, key, candidates):
    if key in raw:
        return profile_paths(raw[key], key), "profile"
    detected = tuple(path for path in candidates if (root / path).is_dir())
    return detected, "detected:" + ",".join(detected) if detected else "default"


def load_profile(cwd):
    root = project_root(cwd)
    path = root / ".session-learnings.json"
    present = path.exists() or path.is_symlink()
    try:
        raw = read_object(path) if present else {}
    except (OSError, ValueError) as error:
        raise StatsError(f"cannot read profile {path}: {error}", 2) from error
    knowledge, ksource = profile_value(raw, root, "knowledge_paths", ("docs/",))
    scripts, ssource = profile_value(raw, root, "script_dirs", ("bin/", "scripts/"))
    return Profile(root, path if present else None, knowledge, scripts,
                   {"knowledge_paths": ksource, "script_dirs": ssource})


def explain(cwd):
    profile = load_profile(cwd)
    return {
        "plugin": "session-learnings", "profile_file": str(profile.file) if profile.file else None,
        "values": {"knowledge_paths": profile.knowledge, "script_dirs": profile.scripts},
        "sources": profile.sources,
    }


def entries(path, subagent=False):
    try:
        with path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or row.get("isMeta") is True:
                    continue
                if row.get("isSidechain") is True and not subagent:
                    continue
                yield row
    except OSError as error:
        print(f"session-learnings: skipped transcript {path}: {error.strerror}", file=sys.stderr)


def session_files(projects):
    if not projects.is_dir():
        raise StatsError(f"unreadable projects directory: {projects}", 66)
    try:
        directories = sorted(p for p in projects.iterdir() if p.is_dir())
        for directory in directories:
            grouped = collections.defaultdict(list)
            for path in sorted(directory.glob("*.jsonl")):
                grouped[path.stem].append((path, False))
            for path in sorted(directory.glob("*/subagents/*.jsonl")):
                grouped[path.parent.parent.name].append((path, True))
            for session, files in sorted(grouped.items()):
                yield directory.name, session, files
    except OSError as error:
        raise StatsError(f"unreadable projects directory: {projects}", 66) from error


def session_context(files):
    cwd, entrypoint = None, None
    for path, subagent in files:
        for row in entries(path, subagent):
            if not cwd and isinstance(row.get("cwd"), str) and Path(row["cwd"]).is_absolute():
                cwd = row["cwd"]
            if not entrypoint and isinstance(row.get("entrypoint"), str):
                entrypoint = row["entrypoint"]
            if cwd and entrypoint:
                return cwd, entrypoint
    return cwd, entrypoint


def in_window(row, start, now):
    try:
        return start <= timestamp(row.get("timestamp")) < now
    except (ValueError, OverflowError):
        return False


def text_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(part["text"] for part in content if isinstance(part, dict)
                         and part.get("type") == "text" and isinstance(part.get("text"), str))
    return ""


def shell_tokens(source):
    tokens, word, quote, started, index = [], "", None, False, 0
    while index < len(source):
        char = source[index]
        if char == "\\" and quote != "'" and index + 1 < len(source):
            escaped = source[index + 1]
            word += escaped if escaped != "\n" else ""
            started = started or escaped != "\n"
            index += 2
            continue
        if quote:
            if char == quote:
                quote = None
            else:
                word += char
            index += 1
            continue
        if char in "\"'":
            quote, started = char, True
            index += 1
            continue
        if char == "#" and not started:
            index = source.find("\n", index)
            if index == -1:
                break
            continue
        operator = OPERATORS.match(source, index)
        if char.isspace() or operator:
            if started:
                tokens.append(ShellToken(word))
            word, started = "", False
            if operator:
                tokens.append(ShellToken(operator.group(), True))
            index = operator.end() if operator else index + 1
            continue
        word, started, index = word + char, True, index + 1
    if quote:
        return []
    return tokens + ([ShellToken(word)] if started else [])


def without_heredocs(command):
    lines, pending = [], []
    for line in command.splitlines(keepends=True):
        if pending:
            delimiter, strip_tabs = pending[0]
            content = line.rstrip("\r\n")
            if (content.lstrip("\t") if strip_tabs else content) == delimiter:
                pending.pop(0)
            continue
        lines.append(line)
        tokens = shell_tokens(line)
        pending.extend((right.text, left.text == "<<-") for left, right in zip(tokens, tokens[1:])
                       if left.operator and left.text in {"<<", "<<-"} and not right.operator)
    return "".join(lines)


def command_words(words):
    while words and (words[0] in SHELL_WORDS or ASSIGNMENT.match(words[0])):
        words = words[1:]
    return [] if not words or words[0] in DECLARATIONS else words


def bash_segments(command):
    if not isinstance(command, str):
        return []
    tokens = shell_tokens(without_heredocs(command))
    segments, current, index = [], [], 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if token.operator and any(c in token.text for c in "<>"):
            if current and current[-1].isdigit():
                current.pop()
            index += 1
            continue
        if token.operator:
            if current:
                segments.append(command_words(current))
            current = []
            continue
        current.append(token.text)
    return [s for s in segments + [command_words(current)] if s]


def relative_path(raw, root, cwd):
    if not isinstance(raw, str) or not raw or raw.startswith("-"):
        return None
    path = Path(raw)
    try:
        absolute = path if path.is_absolute() else cwd / path
        return absolute.resolve().relative_to(root)
    except (OSError, ValueError, RuntimeError):
        return None


def script_path(head, profile, cwd):
    relative = relative_path(head, profile.root, cwd)
    if relative is None:
        return None
    name = relative.as_posix()
    if relative.suffix in SCRIPT_SUFFIXES or any(name.startswith(p) for p in profile.scripts):
        return name
    return None


def script_argument(words):
    program, arguments = executable_name(words[0]), words[1:]
    if program == "uv" and arguments[:1] == ["run"]:
        program, arguments = "uv", arguments[1:]
    elif program not in INTERPRETERS:
        return None
    value_flags = {"-W", "-X", "-r", "--require", "--loader", "--import", "--project", "--directory", "--python"}
    skip_value = False
    for argument in arguments:
        if skip_value:
            skip_value = False
            continue
        if argument == "-" or inline_code_flag(program, argument):
            return None
        if argument in value_flags:
            skip_value = True
            continue
        if not argument.startswith("-"):
            return argument
    return None


def inline_code_flag(program, argument):
    modes = {"bash": {"-c", "--command"}, "sh": {"-c"}, "zsh": {"-c"},
             "python": {"-c", "-m"}, "python3": {"-c", "-m"},
             "node": {"-e", "--eval", "-p", "--print"}, "bun": {"-e", "--eval", "-p", "--print"}}
    if not argument.startswith("-"):
        return False
    if argument.split("=", 1)[0] in modes.get(program, set()):
        return True
    if program in {"bash", "sh", "zsh"} and not argument.startswith("--"):
        return "c" in argument
    return program in {"python", "python3", "node", "bun"} and argument[:2] in modes.get(program, set())


def command_head(words):
    program = executable_name(words[0])
    if len(words) > 1 and SAFE_SECOND.fullmatch(words[1]):
        return program + " " + words[1]
    return program


def interpreter_command(words):
    program = executable_name(words[0])
    return program in INTERPRETERS or program == "uv" and words[1:2] == ["run"]


def executable_name(word):
    return Path(word).name or word


def knowledge_read(raw, project, cwd, session):
    relative = relative_path(raw, project.profile.root, cwd)
    if relative is None:
        return
    for prefix in project.profile.knowledge:
        try:
            below = relative.relative_to(prefix)
        except ValueError:
            continue
        area = knowledge_area(prefix, below, project.profile.root)
        project.knowledge.add(prefix, session)
        project.areas[prefix][area] += 1


def knowledge_area(prefix, below, root):
    if not below.parts:
        return prefix
    first = below.parts[0]
    if len(below.parts) > 1 or (root / prefix / first).is_dir():
        return prefix + first
    return prefix


def bash_usage(command, project, cwd, session):
    for words in bash_segments(command):
        path = script_path(words[0], project.profile, cwd)
        argument = script_argument(words)
        if not path and argument:
            path = script_path(argument, project.profile, cwd)
        program = executable_name(words[0])
        if path:
            project.scripts.add(path, session)
        elif program not in IGNORED and not interpreter_command(words):
            project.hand_rolled.add(command_head(words), session)
        if program in READERS:
            for raw in dict.fromkeys(words[1:]):
                knowledge_read(raw, project, cwd, session)


def tool_usage(tool, project, skills, cwd, session):
    data = tool.get("input")
    if not isinstance(data, dict):
        return
    name = tool.get("name")
    if name == "Skill" and isinstance(data.get("skill"), str) and data["skill"]:
        skills.add(data["skill"].lstrip("/"), session)
    if name == "Read":
        knowledge_read(data.get("file_path"), project, cwd, session)
    if name in {"Grep", "Glob"}:
        knowledge_read(data.get("path"), project, cwd, session)
    if name == "Bash":
        bash_usage(data.get("command"), project, cwd, session)


def row_usage(row, project, skills, session, seen):
    message = row.get("message")
    if not isinstance(message, dict):
        return
    content = message.get("content")
    if row.get("type") == "user":
        identity = row.get("uuid") if isinstance(row.get("uuid"), str) else None
        if identity and ("user", identity) in seen:
            return
        if identity:
            seen.add(("user", identity))
        for name in COMMAND.findall(text_content(content)):
            skills.add(name, session)
        return
    if row.get("type") != "assistant" or not isinstance(content, list):
        return
    cwd = Path(row["cwd"]) if isinstance(row.get("cwd"), str) else project.profile.root
    for tool in content:
        if not isinstance(tool, dict) or tool.get("type") != "tool_use":
            continue
        identity = tool.get("id") if isinstance(tool.get("id"), str) else None
        if identity and ("tool", identity) in seen:
            continue
        if identity:
            seen.add(("tool", identity))
        tool_usage(tool, project, skills, cwd, session)


def active_entries(files, start, now):
    for path, subagent in files:
        for row in entries(path, subagent):
            if in_window(row, start, now):
                yield row


def scan_session(rows, project, skills, session):
    seen = set()
    for row in rows:
        row_usage(row, project, skills, session, seen)
    project.sessions.add(session)


def unread_areas(profile, prefix, reads):
    directory = profile.root / prefix
    try:
        return sorted(prefix + p.name for p in directory.iterdir() if p.is_dir() and prefix + p.name not in reads)
    except OSError:
        return []


def knowledge_rows(project):
    rows = []
    for prefix in project.profile.knowledge:
        areas = project.areas[prefix]
        rows.append({
            "path": prefix, "reads": project.knowledge.totals[prefix],
            "sessions_reading": len(project.knowledge.sessions[prefix]),
            "areas": [{"area": name, "reads": count}
                      for name, count in sorted(areas.items(), key=lambda row: (-row[1], row[0]))],
            "unread_areas": unread_areas(project.profile, prefix, areas),
        })
    return sorted(rows, key=lambda row: (-row["reads"], row["path"]))


def project_row(project):
    return {
        "slug": project.slug, "root": str(project.profile.root), "sessions": len(project.sessions),
        "scripts": project.scripts.rows("path", "runs"),
        "hand_rolled": project.hand_rolled.rows("head", "runs"), "knowledge": knowledge_rows(project),
    }


def dormant_skills(config, now):
    try:
        usage = read_object(config).get("skillUsage", {})
    except (OSError, ValueError):
        return []
    if not isinstance(usage, dict):
        return []
    rows = [dormant_row(name, value, now) for name, value in usage.items()]
    return sorted((r for r in rows if r), key=lambda r: (-r["lifetime"], r["name"]))


def dormant_row(name, value, now):
    if not name or not isinstance(value, dict):
        return None
    count, used = value.get("usageCount"), value.get("lastUsedAt")
    if type(count) is not int or type(used) is not int or min(count, used) < 0:
        return None
    try:
        last = dt.datetime.fromtimestamp(used / 1000, UTC)
    except (ValueError, OverflowError, OSError):
        return None
    if last >= now - dt.timedelta(days=30):
        return None
    return {"name": name, "last_used": iso(last), "lifetime": count}


def scan_projects(args, start, now):
    projects, profiles, skills = {}, {}, Counts()
    sessions = {"total": 0, "interactive": 0, "headless": 0}
    for slug, session_id, files in session_files(Path(args.projects_dir).expanduser()):
        cwd, entrypoint = session_context(files)
        if not cwd:
            continue
        entries_in_window = active_entries(files, start, now)
        first = next(entries_in_window, None)
        if first is None:
            continue
        if slug not in projects:
            if cwd not in profiles:
                profiles[cwd] = load_profile(cwd)
            projects[slug] = Project(slug, profiles[cwd])
        scan_session(itertools.chain((first,), entries_in_window), projects[slug], skills, (slug, session_id))
        sessions["total"] += 1
        sessions["interactive" if entrypoint in INTERACTIVE else "headless"] += 1
    return projects, skills, sessions


def build_report(args, now):
    start = now - dt.timedelta(days=args.days)
    projects, skills, sessions = scan_projects(args, start, now)
    rows = [project_row(p) for p in projects.values() if p.sessions]
    return {"week": week(now), "window": {"from": iso(start), "to": iso(now), "days": args.days},
            "generated_at": iso(now), "sessions": sessions, "skills": skills.rows("name", "loads"),
            "dormant_skills": dormant_skills(Path(args.config).expanduser(), now),
            "projects": sorted(rows, key=lambda row: (-row["sessions"], row["slug"]))}


def proposal(kind, project, subject, evidence, suggestion, report_week):
    key = f"{kind}|{project or ''}|{subject}"
    return {"id": "prp-" + hashlib.sha256(key.encode()).hexdigest()[:12], "kind": kind,
            "project": project, "subject": subject, "evidence": evidence, "suggestion": suggestion,
            "status": "open", "week": report_week}


def knowledge_proposals(project, report_week):
    rows, total = [], project["sessions"]
    for knowledge in project["knowledge"]:
        path, reading = knowledge["path"], knowledge["sessions_reading"]
        if total >= 10 and reading / total < 0.25:
            rows.append(proposal("knowledge-gap", project["slug"], path,
                                 f"{reading} of {total} sessions read {path}",
                                 f"route more tasks to {path} first", report_week))
        if knowledge["unread_areas"]:
            rows.append(proposal("unread-areas", project["slug"], path,
                                 "unread areas: " + ", ".join(knowledge["unread_areas"]),
                                 f"review discoverability of unread areas in {path}", report_week))
    return rows


def project_proposals(project, report_week):
    rows = knowledge_proposals(project, report_week)
    heads = sorted(project["hand_rolled"], key=lambda row: (-row["runs"], row["head"]))
    eligible = [row for row in heads if row["runs"] >= 10 and row["sessions"] >= 3]
    for row in eligible:
        rows.append(proposal("hand-rolled", project["slug"], row["head"],
                             f"{row['runs']} runs across {row['sessions']} sessions",
                             "check for an existing script or skill before adding a wrapper", report_week))
    return rows


def derive_proposals(report):
    rows = [row for p in report["projects"] for row in project_proposals(p, report["week"])]
    for skill in sorted(report["dormant_skills"], key=lambda row: (-row["lifetime"], row["name"])):
        rows.append(proposal("dormant-skill", None, skill["name"],
                             f"last used {skill['last_used']}; {skill['lifetime']} lifetime loads",
                             "review whether to retire the skill or improve its trigger", report["week"]))
    return sorted(rows, key=lambda row: (row["kind"], row["project"] or ""))


def latest_report(store):
    paths = sorted(p for p in (store / "usage").glob("*.json") if REPORT_NAME.fullmatch(p.name))
    return read_object(paths[-1]) if paths else None


def read_decisions(store):
    path = store / "proposals.jsonl"
    if not path.exists():
        return {}
    decisions = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if not isinstance(event, dict) or event.get("event") not in DECISIONS:
            raise StatsError("invalid proposal decision ledger")
        timestamp(event["ts"])
        previous = decisions.get(event["id"])
        if not previous or timestamp(previous["ts"]) <= timestamp(event["ts"]):
            decisions[event["id"]] = event
    return decisions


def proposal_status(row, decision, now):
    if not decision:
        return "open"
    kind, moment = decision["event"], timestamp(decision["ts"])
    if kind == "rejected" and now >= moment + dt.timedelta(days=90):
        return "open"
    if kind == "deferred" and row["week"] > week(moment):
        return "open"
    return kind


def proposals(store, now):
    report = latest_report(store)
    if not report:
        return []
    decisions = read_decisions(store)
    return [dict(row, status=proposal_status(row, decisions.get(row["id"]), now))
            for row in derive_proposals(report)]


def visible_proposals(rows, project, status):
    counts = collections.Counter()
    for row in rows:
        if project and row["project"] not in (None, project):
            continue
        if status == "all":
            yield row
            continue
        key = row["kind"], row["project"]
        if row["status"] == "open" and counts[key] < 5:
            counts[key] += 1
            yield row


def real_directory(path):
    if path.is_symlink():
        raise StatsError(f"refusing symlink directory: {path}")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)


@contextmanager
def store_lock(store):
    real_directory(store)
    descriptor = os.open(store / ".stats.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def atomic_json(path, value):
    if path.is_symlink():
        raise StatsError(f"refusing symlink report: {path}")
    descriptor, temporary = tempfile.mkstemp(prefix=".sl-stats-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_report(args, store, now):
    path = store / "usage" / (week(now) + ".json")
    with store_lock(store):
        real_directory(path.parent)
        if path.is_symlink():
            raise StatsError(f"refusing symlink report: {path}")
        if not (args.if_stale and path.is_file()):
            atomic_json(path, build_report(args, now))
    print(path)


def decide(args, store, now):
    with store_lock(store):
        if not any(row["id"] == args.id for row in proposals(store, now)):
            raise StatsError("unknown proposal id: " + args.id, 65)
        event = {"event": args.type, "id": args.id, "note": args.note or "", "ts": iso(now)}
        descriptor = os.open(store / "proposals.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(event, ensure_ascii=False) + "\n")
            stream.flush()
            os.fsync(stream.fileno())


def parse_args(argv):
    parser = Parser(prog="sl-stats.sh", allow_abbrev=False)
    parser.add_argument("verb", nargs="?", choices=("report", "proposals", "decide"))
    parser.add_argument("--store", default=os.environ.get("SESSION_LEARNINGS_HOME", "~/.claude/learnings"))
    config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
    parser.add_argument("--projects-dir", default=str(config_dir / "projects"))
    config_home = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home()))
    parser.add_argument("--config", default=str(config_home / ".claude.json"))
    parser.add_argument("--now")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--if-stale", action="store_true")
    parser.add_argument("--project")
    parser.add_argument("--status", choices=("open", "all"), default="open")
    parser.add_argument("--id")
    parser.add_argument("--type", choices=sorted(DECISIONS))
    parser.add_argument("--note")
    parser.add_argument("--explain", action="store_true")
    parser.add_argument("--project-dir", default=str(Path.cwd()))
    args = parser.parse_args(argv)
    if (not args.verb and not args.explain) or (args.verb and args.explain) or args.days <= 0:
        raise StatsError("choose report, proposals, decide, or --explain; days must be positive")
    if args.verb == "decide" and (not args.id or not args.type):
        raise StatsError("decide requires --id and --type")
    return args


def run(args):
    if args.explain:
        print(json.dumps(explain(args.project_dir)))
        return
    now = timestamp(args.now) if args.now else dt.datetime.now(UTC)
    store = Path(args.store).expanduser().absolute()
    if args.verb == "report":
        write_report(args, store, now)
    if args.verb == "decide":
        decide(args, store, now)
    if args.verb == "proposals":
        for row in visible_proposals(proposals(store, now), args.project, args.status):
            print(json.dumps(row, ensure_ascii=False))


def main(argv):
    os.umask(0o077)
    try:
        run(parse_args(argv))
    except StatsError as error:
        print("session-learnings: " + str(error), file=sys.stderr)
        return error.code
    except (OSError, ValueError, OverflowError, KeyError, TypeError) as error:
        print("session-learnings: stats failed: " + str(error), file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
