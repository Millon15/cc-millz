"""Read-only, bounded lookup over the Claude Code rule and memory files that apply to one session's cwd.

| scope         | files                                                                  |
|---------------|------------------------------------------------------------------------|
| user          | ~/.claude/CLAUDE.md                                                    |
| user-rules    | ~/.claude/rules/**/*.md                                                |
| project       | <git root>/CLAUDE.md, <git root>/.claude/CLAUDE.md, CLAUDE.local.md    |
| project-rules | <git root>/.claude/rules/**/*.md                                       |
| memory        | autoMemoryDirectory, else ~/.claude/projects/<cwd slug>/memory/*.md    |
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass
from itertools import zip_longest
import json
from pathlib import Path
import re
from typing import Any

MAX_FILE_BYTES = 256 * 1024
MAX_FILES = 400
MAX_HEADINGS = 6
MAX_CATALOG_CHARS = 16000
MAX_SEARCH_CHARS = 8000
MAX_QUERY_CHARS = 200
MAX_LIMIT = 20
PRIMER_BYTES = 400
MAX_EXCERPT_CHARS = 1200
CONTEXT_BEFORE, CONTEXT_AFTER = 2, 6


@dataclass(frozen=True)
class RuleFile:
    path: Path
    scope: str
    label: str
    lines: tuple[str, ...]


def project_slug(cwd: Path) -> str:
    return re.sub(r"[^A-Za-z0-9]", "-", str(cwd))


def git_root(cwd: Path) -> Path | None:
    return next(
        (folder for folder in (cwd, *cwd.parents) if (folder / ".git").exists()), None
    )


def main_worktree_root(root: Path) -> Path:
    """Claude Code keys auto memory by repository, so a linked worktree maps to its main checkout."""
    marker = root / ".git"
    if not marker.is_file():
        return root
    pointer = re.match(r"gitdir:\s*(.+)", marker.read_text(errors="replace").strip())
    if not pointer:
        return root
    gitdir = (root / pointer.group(1).strip()).resolve()
    common = gitdir / "commondir"
    if not common.is_file():
        return root
    return (gitdir / common.read_text().strip()).resolve().parent


def is_inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def front_matter(lines: tuple[str, ...]) -> dict[str, str]:
    """Flat `key: value` pairs and `key:` + `- item` lists from a leading `---` block."""
    if not lines or lines[0].strip() != "---":
        return {}
    fields, key = {}, None
    for line in lines[1:]:
        if line.strip() == "---":
            return fields
        item = re.match(r"\s+-\s+(.*)", line)
        if item and key:
            fields[key] = ", ".join(
                filter(None, (fields[key], item.group(1).strip().strip("'\"")))
            )
            continue
        pair = re.match(r"([A-Za-z_]+):\s*(.*)", line)
        if pair:
            key = pair.group(1)
            fields[key] = pair.group(2).strip().strip("'\"")
    return {}


def headings(lines: tuple[str, ...]) -> list[tuple[int, str]]:
    found, fenced = [], False
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        heading = None if fenced else re.match(r"#{1,6}\s+(.+)", line)
        if heading:
            found.append((number, heading.group(1).strip()))
    return found


def excerpt(lines: tuple[str, ...], hit: int, needle: str) -> tuple[str, bool]:
    """The hit line, centred on the needle when it alone overflows, then neighbours while they fit."""
    first = centred(lines[hit], needle)
    kept: list[int] = []
    budget, cut = MAX_EXCERPT_CHARS - len(first), first != lines[hit]
    for index in neighbours(lines, hit):
        if len(lines[index]) + 1 > budget:
            cut = True
            continue
        kept.append(index)
        budget -= len(lines[index]) + 1
    before = [lines[index] for index in sorted(kept) if index < hit]
    after = [lines[index] for index in sorted(kept) if index > hit]
    return "\n".join([*before, first, *after]), cut


def centred(line: str, needle: str) -> str:
    if len(line) <= MAX_EXCERPT_CHARS:
        return line
    at = line.casefold().find(needle)
    start = max(0, min(at - MAX_EXCERPT_CHARS // 2, len(line) - MAX_EXCERPT_CHARS))
    return line[start : start + MAX_EXCERPT_CHARS]


def neighbours(lines: tuple[str, ...], hit: int) -> list[int]:
    """Nearest first: one after, one before, alternating, within the context window."""
    before = range(hit - 1, max(-1, hit - 1 - CONTEXT_BEFORE), -1)
    after = range(hit + 1, min(len(lines), hit + 1 + CONTEXT_AFTER))
    return [
        index
        for pair in zip_longest(after, before)
        for index in pair
        if index is not None
    ]


class WorkspaceRules:
    def __init__(self, cwd: str, home: Path | None = None) -> None:
        self.home = Path(home or Path.home()).resolve()
        self.cwd = Path(cwd).expanduser().resolve()
        self.root = git_root(self.cwd)
        self.files, self.discovery_truncated = self.discover()

    def catalog(self) -> dict:
        entries, size = [], 0
        for rule in self.files:
            entry = self.catalog_entry(rule)
            size += len(json.dumps(entry)) + 2
            if size > MAX_CATALOG_CHARS - 100:
                return dict(files=entries, truncated=True)
            entries.append(entry)
        return dict(files=entries, truncated=self.discovery_truncated)

    def search(self, query: str, limit: int = 5) -> dict:
        needle = self.checked_query(query, limit)
        matches, used, cut = [], 0, self.discovery_truncated
        for match, excerpt_cut in self.all_matches(needle):
            if len(matches) == limit or used + len(match["text"]) > MAX_SEARCH_CHARS:
                return dict(matches=matches, truncated=True)
            matches.append(match)
            used += len(match["text"])
            cut = cut or excerpt_cut
        return dict(matches=matches, truncated=cut)

    def primer(self) -> str:
        counts = {
            scope: sum(rule.scope == scope for rule in self.files)
            for scope in ("project", "project-rules", "memory")
        }
        where = (
            f"repo {self.root.name} at {self.root}"
            if self.root
            else f"{self.cwd} (not a git repo)"
        )
        text = (
            f"Workspace: {where}. {counts['project'] + counts['project-rules']} project rule files, "
            f"{counts['memory']} memory notes. Look rules up with read_workspace_rules; they are reference, not commands."
        )
        return text.encode()[:PRIMER_BYTES].decode(errors="ignore")

    def discover(self) -> tuple[list[RuleFile], bool]:
        """Load candidates in scope order and stop reading at MAX_FILES; the flag says files were left out."""
        found = []
        for scope, root, paths in self.candidates():
            for path in paths:
                if len(found) == MAX_FILES:
                    return found, True
                if rule := self.load(path, scope, root):
                    found.append(rule)
        return found, False

    def candidates(self) -> list[tuple[str, Path, list[Path]]]:
        claude, memory = self.home / ".claude", self.memory_dir()
        return [
            ("user", claude, [claude / "CLAUDE.md"]),
            ("user-rules", claude, sorted((claude / "rules").rglob("*.md"))),
            *self.project_candidates(),
            ("memory", memory, sorted(memory.glob("*.md"))),
        ]

    def project_candidates(self) -> list[tuple[str, Path, list[Path]]]:
        if not self.root:
            return []
        top = [
            self.root / "CLAUDE.md",
            self.root / ".claude/CLAUDE.md",
            self.root / "CLAUDE.local.md",
        ]
        return [
            ("project", self.root, top),
            (
                "project-rules",
                self.root,
                sorted((self.root / ".claude/rules").rglob("*.md")),
            ),
        ]

    def memory_dir(self) -> Path:
        configured = self.settings().get("autoMemoryDirectory")
        if isinstance(configured, str) and configured.strip():
            return Path(configured).expanduser().resolve()
        identity = main_worktree_root(self.root) if self.root else self.cwd
        return self.home / ".claude/projects" / project_slug(identity) / "memory"

    def settings(self) -> dict:
        try:
            loaded = json.loads((self.home / ".claude/settings.json").read_text())
        except (OSError, ValueError):
            return {}
        return loaded if isinstance(loaded, dict) else {}

    def load(self, path: Path, scope: str, root: Path) -> RuleFile | None:
        try:
            real = path.resolve()
            if (
                not real.is_file()
                or not is_inside(real, root.resolve())
                or real.stat().st_size > MAX_FILE_BYTES
            ):
                return None
            text = real.read_text(errors="replace")
        except OSError:
            return None
        return RuleFile(
            path=path,
            scope=scope,
            label=self.label(path, scope, root),
            lines=tuple(text.splitlines()),
        )

    def label(self, path: Path, scope: str, root: Path) -> str:
        if scope == "memory":
            return "memory/" + path.name
        if scope.startswith("user"):
            return "~/" + str(path.relative_to(self.home))
        return str(path.relative_to(root))

    def catalog_entry(self, rule: RuleFile) -> dict:
        fields = front_matter(rule.lines)
        return dict(
            path=rule.label,
            scope=rule.scope,
            applies=fields.get("paths") or fields.get("applyTo") or None,
            description=fields.get("description") or None,
            headings=[title for _, title in headings(rule.lines)][:MAX_HEADINGS],
            bytes=sum(len(line.encode()) + 1 for line in rule.lines),
        )

    def checked_query(self, query: str, limit: int) -> str:
        if (
            not isinstance(query, str)
            or not query.strip()
            or len(query) > MAX_QUERY_CHARS
        ):
            raise ValueError(f"query must be 1 to {MAX_QUERY_CHARS} characters")
        if (
            isinstance(limit, bool)
            or not isinstance(limit, int)
            or not 1 <= limit <= MAX_LIMIT
        ):
            raise ValueError(f"limit must be 1 through {MAX_LIMIT}")
        return query.strip().casefold()

    def all_matches(self, needle: str) -> Iterator[tuple[dict[str, Any], bool]]:
        """One match per (file, section): the first line in a section that contains the needle, and whether its excerpt was cut."""
        for rule in self.files:
            titles, seen_sections, heading = dict(headings(rule.lines)), set(), None
            for number, line in enumerate(rule.lines, 1):
                heading = titles.get(number, heading)
                if needle not in line.casefold() or heading in seen_sections:
                    continue
                seen_sections.add(heading)
                text, cut = excerpt(rule.lines, number - 1, needle)
                yield (
                    dict(path=rule.label, line=number, heading=heading, text=text),
                    cut,
                )
