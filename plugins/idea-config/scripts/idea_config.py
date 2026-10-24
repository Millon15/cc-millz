#!/usr/bin/env python3
"""Inspect JetBrains project files and preserve pre-edit snapshots."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote
import xml.etree.ElementTree as ET
from xml.parsers import expat


IDES = {"phpstorm", "goland", "pycharm", "intellij", "webstorm", "rider", "clion", "rubymine", "unknown"}
SKIP_DIRS = {".git", ".idea", ".run", "node_modules", "vendor"}
PROCESS_NAMES = IDES - {"unknown"} | {"idea", "idea64", "pycharm64", "phpstorm64", "goland64",
                                         "webstorm64", "rider64", "clion64", "rubymine64"}


@dataclass(frozen=True)
class Finding:
    kind: str
    file: str
    line: int | None
    detail: str


@dataclass(frozen=True)
class Document:
    path: Path
    element: ET.Element
    lines: dict


@dataclass(frozen=True)
class Config:
    root: Path
    profile_file: Path | None
    values: dict
    sources: dict


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=("doctor", "backup"))
    parser.add_argument("--root", type=Path, help="project containing .idea; otherwise search cwd ancestors")
    parser.add_argument("--explain", action="store_true", help="print resolved config and provenance")
    parser.add_argument("--json", action="store_true", help="JSON doctor findings")
    args = parser.parse_args()
    if args.explain == bool(args.command) or (args.json and args.command != "doctor"):
        parser.error("choose --explain, doctor [--json], or backup")
    return parser, args


def project_root(explicit):
    candidates = [explicit.expanduser().resolve()] if explicit else [Path.cwd(), *Path.cwd().parents]
    for candidate in candidates:
        if (candidate / ".idea").is_dir() and not (candidate / ".idea").is_symlink():
            return candidate
    raise ValueError("no project found; looked for a non-symlink .idea directory in --root or cwd ancestors")


def read_profile(root):
    path = root / ".idea-config.json"
    if not path.exists() and not path.is_symlink():
        return None, {}
    profile = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(profile, dict) or set(profile) - {"ide", "backup_dir"}:
        raise ValueError(".idea-config.json must be an object with only ide and backup_dir keys")
    if "ide" in profile and (not isinstance(profile["ide"], str) or profile["ide"] not in IDES):
        raise ValueError(".idea-config.json ide is not a supported IDE name")
    if "backup_dir" in profile and (not isinstance(profile["backup_dir"], str) or not profile["backup_dir"].strip()):
        raise ValueError(".idea-config.json backup_dir must be a nonempty string")
    return path, profile


def ide_running():
    result = subprocess.run(["ps", "-ax", "-o", "comm="], capture_output=True, text=True, timeout=10, check=True)
    return any(Path(line.strip()).name.lower().removesuffix(".exe") in PROCESS_NAMES
               for line in result.stdout.splitlines())


def detect_ide(root):
    markers = (("php.xml", "phpstorm"), ("go.iml", "goland"), ("riderModule.iml", "rider"))
    hits = [(ide, "detected:.idea/" + marker) for marker, ide in markers if (root / ".idea" / marker).is_file()]
    return hits[0] if len(hits) == 1 else ("unknown", "default")


def resolve_config(explicit):
    root = project_root(explicit)
    profile_path, profile = read_profile(root)
    ide, ide_source = (profile["ide"], "profile") if "ide" in profile else detect_ide(root)
    backup = Path(profile.get("backup_dir", os.environ.get("TMPDIR") or "/tmp")).expanduser()
    if not backup.is_absolute():
        backup = root / backup
    values = {"root": str(root), "idea_dir": str(root / ".idea"), "ide": ide,
              "ide_running": ide_running(), "backup_dir": str(backup.resolve())}
    sources = {"root": "detected:--root" if explicit else "detected:.idea-ancestor",
               "idea_dir": "detected:.idea", "ide": ide_source, "ide_running": "detected:ps",
               "backup_dir": "profile" if "backup_dir" in profile else
               ("detected:TMPDIR" if os.environ.get("TMPDIR") else "default")}
    return Config(root, profile_path, values, sources)


def walk_files(directory):
    if not directory.is_dir() or directory.is_symlink():
        return
    for parent, dirs, files in os.walk(directory, followlinks=False, onerror=raise_io):
        dirs[:] = sorted(name for name in dirs if not (Path(parent) / name).is_symlink())
        for name in sorted(files):
            path = Path(parent) / name
            if path.is_file() and not path.is_symlink():
                yield path


def raise_io(error):
    raise error


def config_files(root):
    files = {p for p in walk_files(root / ".idea") if p.suffix in {".xml", ".iml"}}
    files.update(p for p in root.glob("*.iml") if p.is_file() and not p.is_symlink())
    files.update(p for p in walk_files(root / ".run") if p.suffix == ".xml")
    return files


def parse_xml(path):
    builder, lines, parser = ET.TreeBuilder(), {}, expat.ParserCreate()

    def start(name, attrs):
        element = builder.start(name, attrs)
        lines[element] = parser.CurrentLineNumber

    def reject_doctype(*_):
        raise ValueError("DTD declarations are not supported")

    parser.StartElementHandler = start
    parser.EndElementHandler = builder.end
    parser.CharacterDataHandler = builder.data
    parser.StartDoctypeDeclHandler = reject_doctype
    with path.open("rb") as source:
        parser.ParseFile(source)
    return Document(path, builder.close(), lines)


def path_value(value, root, module_dir):
    if value.startswith("file://"):
        value = unquote(value[7:])
    elif value.startswith("jar://"):
        value = unquote(value[6:].split("!/", 1)[0])
    elif "://" in value:
        return None
    value = value.replace("$PROJECT_DIR$", str(root)).replace("$MODULE_DIR$", str(module_dir))
    if re.search(r"\$[^$]+\$", value):
        return None
    path = Path(value)
    return Path(os.path.abspath(path if path.is_absolute() else root / path))


def module_directory(path):
    parent = path.parent
    if path.suffix == ".iml" and parent.name == ".idea":
        return parent.parent
    return parent


def document_paths(document, root):
    for element in document.element.iter():
        for key in ("url", "fileurl", "filepath", "directory"):
            value = element.get(key, "")
            if "$PROJECT_DIR$" in value or "$MODULE_DIR$" in value:
                path = path_value(value, root, module_directory(document.path))
                if path is not None:
                    yield element, path


def inside(path, parent):
    return path == parent or parent in path.parents


def safe_project_file(path, root):
    return inside(path.resolve(), root) and not any(p.is_symlink() for p in [path, *path.parents] if inside(p, root))


def read_documents(root):
    pending, seen, documents, findings = sorted(config_files(root)), set(), [], []
    while pending:
        path = pending.pop(0)
        if path in seen:
            continue
        seen.add(path)
        try:
            doc = parse_xml(path)
        except (expat.ExpatError, ValueError) as error:
            findings.append(Finding("invalid-xml", str(path.relative_to(root)), getattr(error, "lineno", None), str(error)))
            continue
        documents.append(doc)
        if path == root / ".idea/modules.xml":
            pending.extend(p for _, p in document_paths(doc, root)
                           if p.suffix == ".iml" and p.is_file() and safe_project_file(p, root))
    return documents, findings


def finding(kind, document, element, detail, root):
    return Finding(kind, str(document.path.relative_to(root)), document.lines.get(element), detail)


def stale_paths(document, root):
    if document.path.name not in {"modules.xml", "vcs.xml"} and document.path.suffix != ".iml":
        return []
    seen, findings = set(), []
    for element, path in document_paths(document, root):
        key = (id(element), path)
        if key not in seen and not path.exists():
            findings.append(finding("stale-path", document, element, f"target does not exist: {path}", root))
        seen.add(key)
    return findings


def duplicates(document, root):
    findings = []
    for parent in document.element.iter():
        seen = set()
        for element in parent:
            if element.tag not in {"sourceFolder", "excludeFolder"}:
                continue
            key = (element.tag, tuple(sorted(element.attrib.items())), (element.text or "").strip(),
                   tuple(ET.tostring(child, encoding="unicode") for child in element))
            if key in seen:
                findings.append(finding("duplicate-entry", document, element, f"repeated {element.tag} element", root))
            seen.add(key)
    return findings


def vcs_mappings(documents, root):
    mappings, findings = set(), []
    for doc in documents:
        if doc.path != root / ".idea/vcs.xml":
            continue
        for element in doc.element.iter("mapping"):
            if element.get("vcs") != "Git":
                continue
            path = path_value(element.get("directory") or str(root), root, doc.path.parent)
            if path is None:
                continue
            mappings.add(path.resolve())
            if not path.is_dir() or not ((path / ".git").is_dir() or (path / ".git").is_file()):
                findings.append(finding("dead-mapping", doc, element, f"no Git directory or worktree marker: {path}", root))
    return mappings, findings


def excluded_directories(documents, root):
    return {path.resolve() for doc in documents if doc.path.suffix == ".iml"
            for element, path in document_paths(doc, root) if element.tag == "excludeFolder"}


def nested_git(root, excluded):
    pending = [(root, 0)]
    while pending:
        parent, depth = pending.pop()
        if depth == 3:
            continue
        for child in sorted(parent.iterdir()):
            if child.name in SKIP_DIRS or child.is_symlink() or not child.is_dir():
                continue
            if any(inside(child, path) for path in excluded):
                continue
            if (child / ".git").is_file() or (child / ".git").is_dir():
                yield child
            pending.append((child, depth + 1))


def diagnose(config):
    documents, findings = read_documents(config.root)
    for document in documents:
        findings.extend(stale_paths(document, config.root))
        findings.extend(duplicates(document, config.root))
    mappings, dead = vcs_mappings(documents, config.root)
    findings.extend(dead)
    for path in nested_git(config.root, excluded_directories(documents, config.root)):
        if path.resolve() not in mappings:
            findings.append(Finding("unmapped-git", ".idea/vcs.xml", None,
                                    f"nested Git root is not mapped: {path.relative_to(config.root)}"))
    if config.values["ide_running"]:
        findings.append(Finding("ide-running", ".idea", None, "info: a JetBrains IDE is running; disk edits may race its model"))
    return sorted(findings, key=lambda item: (item.file, item.line or 0, item.kind, item.detail))


def print_findings(config, as_json):
    findings = diagnose(config)
    if as_json:
        print(json.dumps({"root": str(config.root), "findings": [asdict(item) for item in findings]}))
    else:
        for item in findings:
            detail = " ".join(item.detail.split())
            print(f"{item.kind}\t{item.file}:{item.line or '?'}\t{detail}")
    return int(bool(findings))


def backup_files(root):
    files = {p for p in walk_files(root / ".idea") if p.suffix == ".xml"}
    files.update(p for parent in (root, root / ".idea") for p in parent.glob("*.iml")
                 if p.is_file() and not p.is_symlink())
    files.update(walk_files(root / ".run"))
    return sorted(files)


def backup(config):
    files = backup_files(config.root)
    base = Path(config.values["backup_dir"])
    if inside(base, config.root / ".idea") or inside(base, config.root / ".run"):
        raise ValueError("backup_dir must be outside .idea and .run")
    base.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    destination = base / f"idea-config-backup.{stamp}"
    destination.mkdir(mode=0o700)
    for source in files:
        target = destination / source.relative_to(config.root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        target.chmod(0o600)
    print(destination)
    return 0


def main():
    parser, args = arguments()
    if sys.version_info < (3, 9):
        parser.error("Python 3.9 or newer is required")
    try:
        config = resolve_config(args.root)
        if args.explain:
            print(json.dumps({"plugin": "idea-config", "profile_file": str(config.profile_file) if config.profile_file else None,
                              "values": config.values, "sources": config.sources}))
            return 0
        if args.command == "doctor":
            return print_findings(config, args.json)
        return backup(config)
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
