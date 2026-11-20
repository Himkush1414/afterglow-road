#!/usr/bin/env bash
# Unit tests of the world generator (tools/worldgen/tests).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
# The pinned tools environment (tools/setup_toolchain.sh) when it exists, else the PATH python.
py=python3
[[ -x _local/tools/venv/bin/python ]] && py=_local/tools/venv/bin/python
"${py}" -m unittest discover -s tools/worldgen/tests -t . -v 2>&1
