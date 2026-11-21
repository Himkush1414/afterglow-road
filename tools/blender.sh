#!/usr/bin/env bash
# Runs the pinned Blender binary (headless use: tools/blender.sh -b --python <script> -- <args>).
# BLENDER_BIN overrides the binary.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n '/^\[blender\]/{n;s/^Blender \([0-9.]*\).*/\1/p}' "${root}/_local/tools/TOOLCHAIN.lock" 2>/dev/null || true)"
bin="${BLENDER_BIN:-${root}/_local/tools/blender/${version}/blender}"
[[ -x "${bin}" ]] || { printf 'blender.sh: binary not found: %s\n' "${bin}" >&2; exit 1; }
# Keep Blender's user config and caches inside the working copy.
export BLENDER_USER_RESOURCES="${BLENDER_USER_RESOURCES:-${root}/_local/tools/_home/blender}"
mkdir -p "${BLENDER_USER_RESOURCES}"
exec "${bin}" --factory-startup "$@"
