#!/usr/bin/env bash
# Test for tools/private_terms_scan.sh, using a throw-away repository and
# a throw-away word list of made-up words.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${here}/../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

export GIT_CONFIG_GLOBAL="${sandbox}/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name "scan test"
git config --global user.email "scan-test@example.invalid"
git config --global init.defaultBranch main

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

work="${sandbox}/work"
git init --quiet "${work}"
cd "${work}"
mkdir -p tools game/src
cp "${project_root}/tools/private_terms_scan.sh" tools/
printf '# test list\nZorbleton\nquux harbour\n' >"${sandbox}/terms.txt"
export PRIVATE_TERMS_FILE="${sandbox}/terms.txt"
printf 'func a() -> void:\n\tpass\n' >game/src/a.gd
git add -A && git commit --quiet -m "chore: bootstrap"

if tools/private_terms_scan.sh --files >/dev/null 2>&1; then pass "clean tree passes"; else fail "clean tree passes"; fi

printf '# the road to zorbleton\n' >game/src/b.gd
if tools/private_terms_scan.sh --files >/dev/null 2>&1; then fail "untracked file with a term fails"; else pass "untracked file with a term fails"; fi
out="$(tools/private_terms_scan.sh --files 2>&1 || true)"
if grep -q -i zorbleton <<<"${out}"; then fail "the term is not printed"; else pass "the term is not printed"; fi
if grep -q 'game/src/b.gd:1' <<<"${out}"; then pass "file and line are reported"; else fail "file and line are reported"; fi
rm game/src/b.gd

printf 'Quux Harbour\n' >notes.txt
git add notes.txt
if tools/private_terms_scan.sh --files >/dev/null 2>&1; then fail "phrase match is case-insensitive"; else pass "phrase match is case-insensitive"; fi
git rm --quiet --cached notes.txt && rm notes.txt

printf 'scratch\n' >ignored.log && printf '*.log\n' >.gitignore && printf 'Zorbleton\n' >>ignored.log
if tools/private_terms_scan.sh --files >/dev/null 2>&1; then pass "ignored files are not scanned"; else fail "ignored files are not scanned"; fi
rm ignored.log .gitignore

git update-ref refs/remotes/origin/main HEAD
git commit --quiet --allow-empty -m "feat: walk to Zorbleton"
if tools/private_terms_scan.sh >/dev/null 2>&1; then fail "commit message with a term fails"; else pass "commit message with a term fails"; fi
if tools/private_terms_scan.sh --files >/dev/null 2>&1; then pass "--files ignores messages"; else fail "--files ignores messages"; fi

PRIVATE_TERMS_FILE="${sandbox}/missing.txt" tools/private_terms_scan.sh >"${sandbox}/out" 2>&1 && grep -q SKIPPED "${sandbox}/out" \
	&& pass "missing list is SKIPPED, not silent" || fail "missing list is SKIPPED, not silent"

if ((failures)); then printf '%d private terms scan check(s) failed\n' "${failures}"; exit 1; fi
printf 'all private terms scan checks passed\n'
