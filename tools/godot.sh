#!/usr/bin/env bash
# Runs the pinned Godot editor binary on the project in game/.
#   tools/godot.sh [godot arguments...]
# GODOT_BIN overrides the binary (CI sets it to its own download).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${GODOT_BIN:-${root}/_local/tools/godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64}"
[[ -x "${bin}" ]] || { printf 'godot.sh: engine binary not found: %s\n' "${bin}" >&2; exit 1; }

# Keep user://, logs and caches inside the working copy (ignored folder)
# instead of the home directory, unless the caller set them.
xdg="${root}/_local/tools/_home/xdg"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${xdg}/data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${xdg}/config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${xdg}/cache}"
mkdir -p "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

exec "${bin}" --path "${root}/game" "$@"
