#!/usr/bin/env bash
# Look for credentials before they reach git history.
#
#   tools/secret_scan.sh --staged   # lines being added by the commit in progress
#   tools/secret_scan.sh --tree     # every tracked file (used by tools/check.sh)
#
# Exit status 1 means something that looks like a secret was found. The
# matching text itself is never printed, only the file and the kind of match.
set -euo pipefail

# kind<TAB>extended regular expression. The token patterns demand a realistic
# length after the prefix, so prose that merely names a prefix does not match.
# Passwords are only flagged when the value is a literal: a quoted string, or
# a bare value with no spaces around "=" as in a config file. Code such as
# `password = field.text` or `password="${VARIABLE}"` is left alone.
PATTERNS=$'GitHub classic token\tgh[pousr]_[A-Za-z0-9]{30,}
GitHub fine-grained token\tgithub_pat_[A-Za-z0-9_]{30,}
private key block\t-----BEGIN [A-Z ]*PRIVATE KEY-----
quoted password literal\t[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]*[:=][[:space:]]*["\x27][^"\x27$<{[:space:]]{4,}["\x27]
bare password assignment\t[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=[A-Za-z0-9!@#%^&*_+.,:;/?-]{4,}([[:space:]]|$)
AWS access key id\tAKIA[0-9A-Z]{16}
Google API key\tAIza[0-9A-Za-z_-]{35}
Slack token\txox[abprs]-[A-Za-z0-9-]{10,}'

# Files whose job is to describe the patterns.
is_exempt() {
	case "$1" in
		tools/secret_scan.sh) return 0 ;;
		*) return 1 ;;
	esac
}

found=0
report() {
	printf 'secret scan: %s: possible %s\n' "$1" "$2" >&2
	found=1
}

scan_text() {
	local file="$1" kind regex
	local text
	text="$(cat)"
	[[ -n "${text}" ]] || return 0
	while IFS=$'\t' read -r kind regex; do
		if grep -qE -e "${regex}" <<<"${text}"; then
			report "${file}" "${kind}"
		fi
	done <<<"${PATTERNS}"
}

mode="${1:-}"
case "${mode}" in
	--staged)
		while IFS= read -r -d '' file; do
			is_exempt "${file}" && continue
			# Process substitution, not a pipe: scan_text must run in this
			# shell or its findings would be lost with the subshell.
			scan_text "${file}" < <(
				git diff --cached --no-color --unified=0 -- "${file}" |
					grep -aE '^\+' | grep -avE '^\+\+\+ ' || true
			)
		done < <(git diff --cached --name-only --diff-filter=ACMR -z)
		;;
	--tree)
		while IFS= read -r -d '' file; do
			is_exempt "${file}" && continue
			[[ -f "${file}" ]] || continue
			grep -Iq . "${file}" 2>/dev/null || continue
			scan_text "${file}" <"${file}"
		done < <(git ls-files -z)
		;;
	*)
		printf 'usage: %s --staged | --tree\n' "$0" >&2
		exit 2
		;;
esac

if ((found)); then
	printf 'secret scan: FAILED. Remove the value, and if it was ever real, revoke and rotate it.\n' >&2
	exit 1
fi
