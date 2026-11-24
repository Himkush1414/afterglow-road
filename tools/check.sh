#!/usr/bin/env bash
# Project checks. One line per suite, then PASS or FAIL.
#
#   tools/check.sh           # full: lint, import, unit tests, content, tool tests, size, privacy
#   tools/check.sh --quick   # lint of changed scripts, secret scan, privacy scan, tool tests
#
# A suite that cannot run here is reported as SKIPPED with the reason; it
# never passes silently.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
quick=0
[[ "${1:-}" == "--quick" ]] && quick=1

log_dir="$(mktemp -d)"
trap 'rm -rf "${log_dir}"' EXIT
failed=0
declare -a summary=()

run() { # name command...
	local name="$1"; shift
	local log="${log_dir}/${name// /_}.log"
	if "$@" >"${log}" 2>&1; then
		summary+=("PASS     ${name}")
	else
		summary+=("FAIL     ${name}")
		failed=1
		# Failures can scroll out of the tail: list them (with their reason
		# lines) first.
		if grep -q '^FAIL  ' "${log}"; then
			printf '\n--- %s (failures) ---\n' "${name}"
			grep -A 8 '^FAIL  ' "${log}" | grep -E '^(FAIL  |      - |--$)'
		fi
		printf '\n--- %s (last 30 lines) ---\n' "${name}"
		tail -n 30 "${log}"
	fi
}
skip() { summary+=("SKIPPED  $1 ($2)"); }

venv="${root}/_local/tools/venv"
gdlint=""
if [[ -x "${venv}/bin/gdlint" ]]; then gdlint="${venv}/bin/gdlint"; elif command -v gdlint >/dev/null; then gdlint="$(command -v gdlint)"; fi

# GDScript lint and format check.
if [[ -n "${gdlint}" ]]; then
	if ((quick)); then
		mapfile -t scripts < <( { git diff --name-only origin/main...HEAD 2>/dev/null; git diff --name-only; git ls-files --others --exclude-standard; } | sort -u | grep '\.gd$' | while read -r f; do [[ -f "$f" ]] && echo "$f"; done)
	else
		mapfile -t scripts < <(git ls-files --cached --others --exclude-standard -- 'game/*.gd' 'tools/*.gd' | while read -r f; do [[ -f "$f" ]] && echo "$f"; done)
	fi
	if ((${#scripts[@]})); then
		run "gdscript lint" "${gdlint}" "${scripts[@]}"
		run "gdscript format" "$(dirname "${gdlint}")/gdformat" --check "${scripts[@]}"
	else
		skip "gdscript lint" "no scripts to check"
	fi
else
	skip "gdscript lint" "gdtoolkit not installed; run tools/setup_toolchain.sh"
fi

run "secret scan" tools/secret_scan.sh --tree
run "private terms scan" tools/private_terms_scan.sh

if ((!quick)); then
	if [[ -n "${GODOT_BIN:-}" || -x "${root}/_local/tools/godot/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64" ]]; then
		run "godot import" tools/godot.sh --headless --import
		run "boot to title" bash -c 'out="$(tools/godot.sh --headless --quit-after 60 2>&1)"; echo "${out}"; grep -q "app: scene title" <<<"${out}" && ! grep -q -E "SCRIPT ERROR|^ERROR" <<<"${out}"'
		if [[ -f game/src/tests/run_tests.gd ]]; then
			run "unit tests" tools/godot.sh --headless -s res://src/tests/run_tests.gd
		else
			skip "unit tests" "test runner not added yet"
		fi
	else
		skip "godot import" "engine binary not found"
		skip "unit tests" "engine binary not found"
	fi
	if [[ -f tools/validate_content.py ]]; then
		run "content (sample)" python3 tools/validate_content.py game/content_sample
		if [[ -d game/content/data ]]; then
			run "content (local)" python3 tools/validate_content.py game/content
		else
			skip "content (local)" "no local content data"
		fi
	else
		skip "content" "validator not added yet"
	fi
	run "file size guard" bash -c 'big=$(git ls-files -z --cached --others --exclude-standard | xargs -0 -r find 2>/dev/null -maxdepth 0 -type f -size +95M); [[ -z "${big}" ]] || { echo "${big}"; exit 1; }'
fi

for t in tests/tools/test_*.sh; do
	run "$(basename "${t}" .sh)" bash "${t}"
done

printf '\n'
printf '%s\n' "${summary[@]}"
if ((failed)); then printf 'CHECK: FAIL\n'; exit 1; fi
printf 'CHECK: PASS\n'
