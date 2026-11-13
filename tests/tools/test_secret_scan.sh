#!/usr/bin/env bash
# Test for tools/secret_scan.sh and the pre-commit hook.
#
# Every fake credential is assembled at run time from harmless pieces, so
# this file never contains a string the scanner would reject.
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
fail() {
	printf '  FAIL  %s\n' "$1"
	failures=$((failures + 1))
}

repeat() { printf "%0.s$1" $(seq 1 "$2"); }

work="${sandbox}/work"
git init --quiet "${work}"
cd "${work}"
mkdir -p tools/git/hooks
cp "${project_root}/tools/secret_scan.sh" tools/
cp "${project_root}/tools/git/hooks/pre-commit" tools/git/hooks/
cp "${project_root}/tools/git/install_hooks.sh" tools/git/
tools/git/install_hooks.sh >/dev/null
git add -A
git commit --quiet -m "chore: bootstrap"

# name | content that must be rejected
declare -A bad=(
	[classic-token]="token: gh""p_$(repeat A 36)"
	[oauth-token]="gh""o_$(repeat b 36)"
	[fine-grained-token]="github""_pat_$(repeat 1 22)_$(repeat c 59)"
	[private-key]="-----BEGIN RSA PRIVATE"" KEY-----"
	[openssh-key]="-----BEGIN OPENSSH PRIVATE"" KEY-----"
	[password-plain]="pass""word=hunter2secret"
	[password-quoted]="PASS""WORD = \"correct-horse\""
	[aws-key]="AK""IA$(repeat Q 16)"
	[google-key]="AI""za$(repeat k 35)"
	[slack-token]="xo""xb-$(repeat 7 12)"
)
# name | content that must be accepted
declare -A good=(
	[prefix-in-prose]="Tokens start with ghp_ or github_pat_ followed by many characters."
	[brief-wording]='scans staged diffs for token patterns (ghp_, github_pat_, private-key headers, "password=") and blocks'
	[password-variable]='password = get_node("%PasswordField").text'
	[password-placeholder]='password=<your password>'
	[password-shell-variable]='password="${KEYSTORE_PASSWORD}"'
	[empty-password]='password='
	[ordinary-code]='var ghost_path: String = "res://content/ghp.tres"'
)

printf 'commits that add a credential are blocked by the hook\n'
for name in "${!bad[@]}"; do
	printf '%s\n' "${bad[${name}]}" >"probe-${name}.txt"
	git add "probe-${name}.txt"
	if output="$(git commit --quiet -m "test: ${name}" 2>&1)"; then
		fail "${name}: commit was allowed"
		git reset --quiet --hard HEAD~1
	else
		if grep -q "probe-${name}.txt: possible" <<<"${output}"; then
			pass "${name}: blocked and reported by file"
		else
			fail "${name}: blocked but not reported"
		fi
		if grep -qF -- "${bad[${name}]}" <<<"${output}"; then
			fail "${name}: the scanner printed the secret"
		fi
	fi
	git reset --quiet
	rm -f "probe-${name}.txt"
done

printf 'harmless look-alikes are accepted\n'
for name in "${!good[@]}"; do
	printf '%s\n' "${good[${name}]}" >"probe-${name}.txt"
	git add "probe-${name}.txt"
	if git commit --quiet -m "test: ${name}" >/dev/null 2>&1; then
		pass "${name}: accepted"
	else
		fail "${name}: wrongly blocked"
		git reset --quiet
		rm -f "probe-${name}.txt"
	fi
done

printf 'whole-tree scan\n'
if tools/secret_scan.sh --tree >/dev/null 2>&1; then
	pass "clean tree passes"
else
	fail "clean tree was rejected"
fi
printf '%s\n' "${bad[classic-token]}" >leaked.txt
git add leaked.txt
git -c core.hooksPath=/dev/null commit --quiet -m "test: bypassed hook"
if tools/secret_scan.sh --tree >/dev/null 2>&1; then
	fail "tree scan missed a committed credential"
else
	pass "tree scan finds a credential that bypassed the hook"
fi
printf 'only removed lines contain the credential\n'
git rm --quiet leaked.txt
if tools/secret_scan.sh --staged >/dev/null 2>&1; then
	pass "removing a credential is not blocked"
else
	fail "removal was blocked"
fi

printf '\n'
if ((failures > 0)); then
	printf '%d check(s) failed\n' "${failures}"
	exit 1
fi
printf 'all secret scan checks passed\n'
