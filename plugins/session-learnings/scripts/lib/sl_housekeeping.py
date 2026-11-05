"""Bounded store maintenance and notification delivery for the Bash worker."""

import argparse
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_archive(path, rows):
    if path.is_symlink():
        raise OSError("symlink archive")
    fd, name = tempfile.mkstemp(prefix=".cleanup-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            for row in rows:
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def old_final_failures(store):
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30)
    selected = []
    for path in sorted((store / "failed").glob("*.json")):
        if path.is_symlink() or not path.is_file():
            continue
        job = json.loads(path.read_text())
        if type(job.get("attempts")) is not int or job["attempts"] < 3:
            continue
        stamp = datetime.datetime.fromisoformat(job["finished_at"].replace("Z", "+00:00"))
        if stamp < cutoff:
            ordered = dict(session_id=job["session_id"], **{k: v for k, v in job.items() if k != "session_id"})
            selected.append((path, ordered))
    return selected


def archive_rows(archive, selected):
    if archive.is_symlink():
        raise OSError("symlink archive")
    rows = [json.loads(line) for line in archive.read_text().splitlines()] if archive.exists() else []
    seen = {json.dumps(row, sort_keys=True) for row in rows}
    for _, job in selected:
        identity = json.dumps(job, sort_keys=True)
        if identity not in seen:
            rows.append(job)
            seen.add(identity)
    return rows


def fold_failures(store):
    selected = old_final_failures(store)
    if not selected:
        return
    archive = store / "failed.jsonl"
    atomic_archive(archive, archive_rows(archive, selected))
    for path, _ in selected:
        path.unlink()


def clean_work(store):
    cutoff = time.time() - 7 * 86400
    for path in (store / "work").iterdir():
        if not path.is_symlink() and path.is_file() and path.stat().st_mtime < cutoff:
            path.unlink()


def rotate_one(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 1024 * 1024:
        return
    previous = path.with_name(path.name + ".1")
    if previous.is_symlink():
        raise OSError("symlink rotated log")
    fd, name = tempfile.mkstemp(prefix=".log-", dir=path.parent)
    try:
        with path.open("r+b") as source, os.fdopen(fd, "wb") as out:
            shutil.copyfileobj(source, out)
            out.flush()
            os.fsync(out.fileno())
            os.replace(name, previous)
            # Preserve the inode: launchd retains open stdout/stderr descriptors.
            source.truncate(0)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def rotate_logs(store):
    for name in ("worker.log", "launchd.out", "launchd.err"):
        rotate_one(store / name)


def deliver(argv):
    try:
        result = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def notify(body):
    override = os.environ.get("SESSION_LEARNINGS_NOTIFY")
    if override == "off":
        return True
    if override:
        return deliver([override, body])
    agterm = shutil.which("agtermctl")
    if agterm and deliver([agterm, "notify", body, "--title", "session-learnings"]):
        return True
    osascript = shutil.which("osascript")
    return bool(osascript) and deliver([
        osascript, "-e", "on run argv", "-e",
        'display notification (item 1 of argv) with title "session-learnings"', "-e", "end run", body,
    ])


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("verb", choices=("fold-failures", "clean-work", "rotate-logs", "notify"))
    parser.add_argument("--store", required=True)
    parser.add_argument("--body")
    args = parser.parse_args(argv)
    if args.verb == "notify" and args.body is None:
        parser.error("notify requires --body")
    try:
        if args.verb == "notify":
            return 0 if notify(args.body) else 1
        actions = {"fold-failures": fold_failures, "clean-work": clean_work, "rotate-logs": rotate_logs}
        actions[args.verb](pathlib.Path(args.store))
        return 0
    except (OSError, ValueError, KeyError, TypeError):
        print("session-learnings: housekeeping failed: " + args.verb, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
