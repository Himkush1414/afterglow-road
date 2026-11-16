#!/usr/bin/env bash
# Runs the pinned Godot editor binary on the project in game/.
#   tools/godot.sh [godot arguments...]
# GODOT_BIN overrides the binary (CI sets it to its own download).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${GODOT_BIN:-${root}/_local/tools/godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
[[ -x "${bin}" ]] || { printf 'godot.sh: engine binary not found: %s\n' "${bin}" >&2; exit 1; }
exec "${bin}" --path "${root}/game" "$@"
