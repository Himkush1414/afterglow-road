#!/usr/bin/env bash
# Unit tests of the world generator (tools/worldgen/tests).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
python3 -m unittest discover -s tools/worldgen/tests -t . -v 2>&1
