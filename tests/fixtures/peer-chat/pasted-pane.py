#!/usr/bin/env python3
"""Print a pane screen whose composer holds the pasted text, for the agtermctl stub of the paste suite.

Usage: pasted-pane.py <pasted text file> <pane screen file>
"""

from __future__ import annotations

from pathlib import Path
import re
import sys

PROMPT = re.compile(r"^(\s*[›»❯])")
RULE = re.compile(r"^\s*─{10,}")
CLAUDE_BOX_END = ["─" * 40, "  ? for shortcuts"]


def last_prompt(lines: list[str]) -> int | None:
    return next(
        (
            index
            for index in range(len(lines) - 1, -1, -1)
            if PROMPT.match(lines[index])
        ),
        None,
    )


def composer_rows(glyph: str, pasted: list[str]) -> list[str]:
    return [
        f"{glyph} {pasted[0]}",
        *(f"  {line}" if line else "" for line in pasted[1:]),
    ]


def closed(glyph: str, below: list[str]) -> list[str]:
    if glyph.strip() != "❯" or any(RULE.match(line) for line in below):
        return below
    return [*below, *CLAUDE_BOX_END]


def render(pasted: list[str], screen: list[str]) -> list[str]:
    index = last_prompt(screen)
    if index is None:
        return [*pasted, "", *screen]
    glyph = PROMPT.match(screen[index]).group(1)
    return [
        *screen[:index],
        *composer_rows(glyph, pasted),
        *closed(glyph, screen[index + 1 :]),
    ]


def main() -> int:
    pasted = Path(sys.argv[1]).read_text(encoding="utf-8").rstrip("\n").split("\n")
    screen = Path(sys.argv[2]).read_text(encoding="utf-8").rstrip("\n").split("\n")
    print("\n".join(render(pasted, screen)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
