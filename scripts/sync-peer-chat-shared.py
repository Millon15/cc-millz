#!/usr/bin/env python3
"""Package canonical Python sources into independently installable peer plugins."""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = {
    "peer_chat_core.py": ("peer-chat", "peer-chat-bg"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for name, plugins in PACKAGES.items():
        source = (ROOT / "shared/peer-chat" / name).read_bytes()
        for plugin in plugins:
            target = ROOT / "plugins" / plugin / "scripts" / name
            if target.exists() and target.read_bytes() == source:
                continue
            if args.check:
                stale.append(str(target.relative_to(ROOT)))
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source)
    if stale:
        print("stale shared copies: " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
