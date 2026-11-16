#!/usr/bin/env bash
# Fail when a file that would be published, or a commit message on the
# current branch, contains a word from the private word list.
#
#   tools/private_terms_scan.sh            # files + messages of commits not on origin/main
#   tools/private_terms_scan.sh --files    # files only
#
# The word list lives outside the repository (one term per line, '#'
# comments, matched case-insensitively). PRIVATE_TERMS_FILE overrides its
# path. Without a list the scan is skipped with a notice (exit 0), which is
# the case on CI.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
list="${PRIVATE_TERMS_FILE:-${root}/_local/env/private_terms.txt}"
mode="${1:-all}"

if [[ ! -f "${list}" ]]; then
	printf 'private terms scan: SKIPPED (no word list at %s)\n' "${list}"
	exit 0
fi

patterns="$(mktemp)"
trap 'rm -f "${patterns}"' EXIT
grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${list}" >"${patterns}" || true
[[ -s "${patterns}" ]] || { printf 'private terms scan: SKIPPED (word list is empty)\n'; exit 0; }

found=0
cd "${root}"
# Tracked files plus new files git would offer to add.
while IFS= read -r -d '' file; do
	[[ -f "${file}" ]] || continue
	if hits="$(grep -n -I -i -F -f "${patterns}" -- "${file}")"; then
		while IFS= read -r line; do
			printf 'private terms scan: %s:%s\n' "${file}" "${line%%:*}" >&2
		done <<<"${hits}"
		found=1
	fi
done < <(git ls-files -z --cached --others --exclude-standard)

if [[ "${mode}" != "--files" ]] && git rev-parse --verify --quiet origin/main >/dev/null; then
	while IFS= read -r sha; do
		if git log -1 --format='%B' "${sha}" | grep -q -i -F -f "${patterns}"; then
			printf 'private terms scan: commit message %s\n' "${sha:0:7}" >&2
			found=1
		fi
	done < <(git rev-list origin/main..HEAD)
fi

if ((found)); then
	printf 'private terms scan: FAIL (matching lines listed above; the terms are not printed)\n' >&2
	exit 1
fi
printf 'private terms scan: clean\n'
