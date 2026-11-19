#!/usr/bin/env bash
# Spike P1-11 driver: start the writer, kill it (SIGKILL) at a random moment,
# verify the save file; N times (default 50). The file must always be the
# old or the new version, never broken, and its generation never goes back.
#   game/src/spikes/save/spike_atomic_save.sh [N] [--direct]
# --direct writes in place without the temporary file (control: must fail).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
godot="${root}/tools/godot.sh"
n="${1:-50}"
mode="${2:-}"
valid=0
broken=0
advanced=0
regress=0
last=-1
for i in $(seq 1 "${n}"); do
	"${godot}" --headless -s res://src/spikes/save/spike_atomic_save_writer.gd -- ${mode} >/dev/null 2>&1 &
	pid=$!
	sleep "$(awk -v r="${RANDOM}" 'BEGIN { printf "%.2f", 0.8 + (r % 120) / 100 }')"
	pkill -9 -P "${pid}" 2>/dev/null
	kill -9 "${pid}" 2>/dev/null
	wait "${pid}" 2>/dev/null
	out="$("${godot}" --headless -s res://src/spikes/save/spike_atomic_save_verify.gd 2>/dev/null | grep -E '^(VALID|BROKEN)')"
	case "${out}" in
		VALID*)
			valid=$((valid + 1))
			g="${out#VALID }"
			g="${g%% *}"
			((g < last)) && regress=$((regress + 1))
			((g > last)) && advanced=$((advanced + 1))
			last="${g}"
			;;
		*)
			broken=$((broken + 1))
			echo "run ${i}: ${out:-no output}"
			;;
	esac
done
echo "valid ${valid}/${n}, broken ${broken}, runs that wrote ${advanced}, generation went back ${regress} times, last generation ${last}"
if ((broken == 0 && regress == 0 && advanced == n)); then
	echo "RESULT PASS"
else
	echo "RESULT FAIL"
	exit 1
fi
