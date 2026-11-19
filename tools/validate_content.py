#!/usr/bin/env python3
"""Validate a content tree (for example game/content_sample) with the game's
own ContentDB checks, run headless. Exit code 0 when it is valid."""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GAME = ROOT / "game"
TIMEOUT_S = 300


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_content.py <content dir under game/>", file=sys.stderr)
        return 2
    tree = pathlib.Path(sys.argv[1]).resolve()
    try:
        rel = tree.relative_to(GAME)
    except ValueError:
        print(f"{tree} is not inside {GAME}", file=sys.stderr)
        return 2
    cmd = [
        str(ROOT / "tools" / "godot.sh"),
        "--headless",
        "-s",
        "res://src/tools/validate_content.gd",
        "--",
        f"res://{rel.as_posix()}",
    ]
    try:
        return subprocess.run(cmd, cwd=ROOT, check=False, timeout=TIMEOUT_S).returncode
    except subprocess.TimeoutExpired:
        print(f"validation did not finish in {TIMEOUT_S} s (script error?)", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
