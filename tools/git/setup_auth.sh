#!/usr/bin/env bash
# Verify that gh can authenticate, wire git to use gh's credentials, and make
# sure a commit identity is configured for this clone.
#
# The identity itself is the owner's choice (CLAUDE.md section 3) and is set
# once with `git config user.name` / `git config user.email`; this script
# checks it but never changes it. gh reads the token from its own store or
# from GH_TOKEN; it is never printed.
set -euo pipefail

# shellcheck source=tools/git/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

login="$(gh api user --jq '.login' 2>/dev/null)" ||
	die "gh cannot authenticate (no accepted token in gh's store or GH_TOKEN); see handoff/NEEDS_OWNER.md"

gh auth setup-git

identity="$(commit_identity)"
[[ "${identity}" != " <>" && "${identity}" != *"<>" && "${identity}" != " <"* ]] ||
	die "no commit identity configured; set user.name and user.email as given in CLAUDE.md section 3"

note "authenticated as ${login}; commits are authored as ${identity}"
