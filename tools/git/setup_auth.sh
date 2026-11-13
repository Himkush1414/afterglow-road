#!/usr/bin/env bash
# Verify the GitHub token, wire git to use it through gh, and set the commit
# identity to the account's no-reply address (CLAUDE.md section 3).
# gh reads the token from its own store or from GH_TOKEN; it is never printed.
set -euo pipefail

# shellcheck source=tools/git/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! identity="$(gh api user --jq '(.id|tostring) + " " + .login' 2>/dev/null)"; then
	die "gh cannot authenticate (no accepted token in gh's store or GH_TOKEN); see handoff/NEEDS_OWNER.md. Git identity left unchanged."
fi
account_id="${identity%% *}"
login="${identity#* }"

gh auth setup-git
git config user.name "${login}"
git config user.email "${account_id}+${login}@users.noreply.github.com"

expected_owner="$(git remote get-url origin | sed -E 's#https://github.com/([^/]+)/.*#\1#')"
note "authenticated as ${login}; commit identity set to the no-reply address"
if [[ "${login}" != "${expected_owner}" ]]; then
	note "note: token account (${login}) differs from the repository owner (${expected_owner}); using the real login as instructed"
fi
