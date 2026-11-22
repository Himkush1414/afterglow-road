#!/usr/bin/env python3
"""Validate a content tree (for example game/content_sample) with the game's
own ContentDB checks, run headless, then the content loop check
(tools/content_loop.py, T-27-1) when the tree configures it. Exit code 0
when both pass."""
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
        code = subprocess.run(cmd, cwd=ROOT, check=False, timeout=TIMEOUT_S).returncode
    except subprocess.TimeoutExpired:
        print(f"validation did not finish in {TIMEOUT_S} s (script error?)", file=sys.stderr)
        return 1
    if code != 0:
        return code
    sys.path.insert(0, str(ROOT / "tools"))
    import content_loop

    lines, bad = content_loop.check(tree)
    for line in lines:
        print(line)
    print(f"LOOP CHECK: {'SKIPPED (not configured)' if bad is None else 'FAIL' if bad else 'PASS'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
