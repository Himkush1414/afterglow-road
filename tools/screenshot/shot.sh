#!/usr/bin/env bash
# Render one frame of a scene to a PNG.
#   tools/screenshot/shot.sh <res://scene.tscn> <out.png> [forward_plus|mobile] [WxH] [frames]
# Needs a display. On a machine without a GPU the engine falls back to a
# software Vulkan driver; the picture is right, the timings are not.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scene="${1:?scene}"; out="${2:?output png}"; method="${3:-forward_plus}"; size="${4:-1280x720}"; frames="${5:-30}"
[[ "${out}" = /* ]] || out="$(pwd)/${out}"
exec "${root}/tools/godot.sh" --rendering-method "${method}" --resolution "${size}" \
	-s res://src/debug/screenshot_runner.gd -- --scene "${scene}" --out "${out}" --frames "${frames}"
