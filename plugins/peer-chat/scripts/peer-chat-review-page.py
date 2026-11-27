#!/usr/bin/env python3
"""Render a design proposal as a commentable agterm page and save the user's comments.

Exit codes: 0 comments saved (or page written with --no-open), 1 agterm failed,
2 usage or unsafe input, 3 the user closed the page without sending.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent / "peer-chat-review-page.html"
PROPOSAL_NAME = re.compile(r"^proposal-v(\d+)\.md$")
ARTIFACT_PREFIX = re.compile(r"^(\d{2})-")
DISMISSED = 2


class UsageError(Exception):
    pass


@dataclass(frozen=True)
class ReviewFiles:
    page: Path
    comments: Path


def main():
    args = parse_args()
    try:
        files = write_page(args.proposal, args.topic_dir, args.pane)
    except UsageError as error:
        return fail(str(error), 2)
    if args.no_open:
        return report({"page": str(files.page)})
    return open_and_collect(files)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--proposal", type=Path, required=True)
    parser.add_argument("--topic-dir", type=Path, required=True)
    parser.add_argument("--pane", choices=("left", "right"), required=True)
    parser.add_argument("--no-open", action="store_true", help="write the page and print its path")
    return parser.parse_args()


def write_page(proposal, topic_dir, pane):
    revision = proposal_revision(proposal)
    markdown = safe_markdown(proposal)
    files = next_files(topic_dir, pane, revision)
    html = TEMPLATE.read_text().replace("__TITLE__", f"proposal-v{revision} review", 1)
    html = html.replace("__MARKDOWN__", markdown, 1)
    create_private(files.page, html)
    return files


def proposal_revision(proposal):
    match = PROPOSAL_NAME.match(proposal.name)
    if not match:
        raise UsageError(f"{proposal} is not a proposal-vN.md file")
    if not proposal.is_file():
        raise UsageError(f"{proposal} does not exist")
    return int(match.group(1))


def safe_markdown(proposal):
    markdown = proposal.read_text()
    if re.search(r"</script", markdown, re.IGNORECASE):
        raise UsageError(f"{proposal} contains '</script', which would end the page's data block")
    return markdown


def next_files(topic_dir, pane, revision):
    if not topic_dir.is_dir():
        raise UsageError(f"{topic_dir} is not a directory")
    number = highest_artifact_number(topic_dir) + 1
    return ReviewFiles(
        page=topic_dir / f"{number:02d}-{pane}-review-v{revision}.html",
        comments=topic_dir / f"{number + 1:02d}-user-comments-v{revision}.json",
    )


def highest_artifact_number(topic_dir):
    numbers = [int(m.group(1)) for p in topic_dir.iterdir() if (m := ARTIFACT_PREFIX.match(p.name))]
    return max(numbers, default=0)


def create_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)


def open_and_collect(files):
    session = os.environ.get("AGTERM_SESSION_ID", "")
    if not session:
        return fail(f"not inside agterm; share {files.page} instead", 2)
    result = subprocess.run(overlay_command(files.page, session), capture_output=True, text=True)
    if result.returncode == DISMISSED:
        return fail(f"dismissed: the page closed without sending; {files.page} still holds the proposal", 3)
    if result.returncode != 0:
        return fail(f"agtermctl exited {result.returncode}: {result.stderr.strip()}", 1)
    return save_comments(files, result.stdout)


def overlay_command(page, session):
    command = ["agtermctl", "session", "overlay", "open", "--html", str(page), "--js", "--block",
               "--size-percent", "95", "--follow", "--target", session]
    socket = os.environ.get("AGTERM_SOCKET", "")
    return command + ["--socket", socket] if socket else command


def save_comments(files, stdout):
    reply = json.loads(stdout)
    if reply.get("outcome") != "submitted":
        return fail(f"unexpected page outcome: {reply.get('outcome')!r}", 1)
    comments = json.loads(reply["value"])
    create_private(files.comments, json.dumps(comments, ensure_ascii=False, indent=2) + "\n")
    count = len(comments.get("comments", [])) + (1 if comments.get("general") else 0)
    return report({"page": str(files.page), "comments": str(files.comments), "count": count})


def report(payload):
    print(json.dumps(payload))
    return 0


def fail(message, code):
    print(f"peer-chat-review-page: {message}", file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
