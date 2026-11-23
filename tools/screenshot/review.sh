#!/usr/bin/env bash
# Capture one set of review frames for the owner (sets live in the content's
# "review" tuning group).
#   tools/screenshot/review.sh <set> [forward_plus|mobile|both] <out dir>
# Needs a display. On a machine without a GPU the engine falls back to a
# software Vulkan driver; the picture is right, the timings are not.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set_name="${1:?set name}"; methods="${2:-both}"; out="${3:?output folder}"
[[ "${out}" = /* ]] || out="$(pwd)/${out}"
[[ "${methods}" == both ]] && methods="forward_plus mobile"
status=0
for m in ${methods}; do
	"${root}/tools/godot.sh" --rendering-method "${m}" res://scenes/debug/review_capture.tscn \
		-- --set "${set_name}" --out "${out}" || status=1
done
exit "${status}"
