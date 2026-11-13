#!/usr/bin/env bash
# Shared helpers for the tools/git scripts. Source it, do not execute it.
# Nothing in here ever prints, stores or passes the GitHub token. gh reads it
# either from its own credential store (`gh auth login --with-token`, run by
# the owner's instruction on 2026-11-13) or from the GH_TOKEN variable.

REPO_ROOT="$(git rev-parse --show-toplevel)"
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"
QUEUE_DIR="${GIT_DIR_ABS}/pr-queue"
GH_STAMP="${GIT_DIR_ABS}/afterglow-gh-last-call"
# The brief demands at least 5 s between pull-request API calls. The override
# exists only so tests/tools/test_git_queue.sh, which talks to a stand-in gh
# and never to GitHub, does not sleep for minutes.
GH_MIN_GAP_SECONDS="${AFTERGLOW_TEST_GH_GAP_SECONDS:-5}"
export REPO_ROOT QUEUE_DIR

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

note() {
	printf '%s\n' "$*" >&2
}

# True when gh can authenticate against github.com with the current token.
gh_online() {
	gh api user --silent >/dev/null 2>&1
}

# gh lets GH_TOKEN override its stored login. A stale or mistyped variable
# (the session's original one is rejected with HTTP 401) would therefore hide
# a perfectly good stored login. When the variable is rejected but the stored
# login works, drop the variable for this process and its children, so that
# gh and the git credential helper both use the stored login.
drop_rejected_env_token() {
	[[ -n "${GH_TOKEN:-}" ]] || return 0
	gh_online && return 0
	if (
		unset GH_TOKEN
		gh_online
	); then
		unset GH_TOKEN
	fi
	return 0
}
drop_rejected_env_token

# "owner/name" of the origin remote on github.com.
remote_slug() {
	git remote get-url origin | sed -E 's#^https://github\.com/##; s#\.git$##'
}

# Print the reason publishing is currently not allowed, or nothing when it is.
# ADR-0002: the source of a paid game is not pushed to a public repository
# unless the owner has said so (git config afterglow.allowPublicRemote true).
publish_blocker() {
	local visibility
	if ! gh_online; then
		printf 'gh has no accepted GitHub credential\n'
		return 0
	fi
	if [[ "$(git config --get --bool afterglow.allowPublicRemote || true)" == "true" ]]; then
		return 0
	fi
	if ! visibility="$(gh api "repos/$(remote_slug)" --jq '.visibility' 2>/dev/null)"; then
		printf 'cannot read the remote repository\n'
		return 0
	fi
	if [[ "${visibility}" != "private" ]]; then
		printf 'remote repository is %s, expected private (ADR-0002)\n' "${visibility}"
	fi
	return 0
}

# The identity new commits get, in the same form as `git log --format='%an <%ae>'`.
commit_identity() {
	printf '%s <%s>\n' "$(git config user.name || true)" "$(git config user.email || true)"
}

# Fail unless every commit the branch adds on top of the given base is
# authored by the configured identity. Pull requests only count for the owner
# when the commits carry the owner's identity.
require_owner_authorship() {
	local base="$1" branch="$2" expected wrong
	expected="$(commit_identity)"
	wrong="$(git log --no-merges --format='%h %an <%ae>' "${base}..${branch}" | grep -vF -- " ${expected}" || true)"
	[[ -z "${wrong}" ]] || die "commits on ${branch} are not authored by ${expected}:
${wrong}"
}

# Number of queued (not yet replayed) entries.
queue_length() {
	local count=0 entry
	if [[ -d "${QUEUE_DIR}" ]]; then
		for entry in "${QUEUE_DIR}"/[0-9][0-9][0-9][0-9]-*; do
			[[ -e "${entry}" ]] && count=$((count + 1))
		done
	fi
	printf '%d\n' "${count}"
}

# Next free four-digit queue number, counting replayed entries too.
queue_next_number() {
	local highest=0 entry base number
	for entry in "${QUEUE_DIR}"/[0-9][0-9][0-9][0-9]-* "${QUEUE_DIR}"/done/[0-9][0-9][0-9][0-9]-*; do
		[[ -e "${entry}" ]] || continue
		base="$(basename "${entry}")"
		number=$((10#${base%%-*}))
		((number > highest)) && highest="${number}"
	done
	printf '%04d\n' "$((highest + 1))"
}

# Sleep until at least GH_MIN_GAP_SECONDS have passed since the previous
# pull-request API call, then record this call.
gh_gap() {
	local now last wait_for
	now="$(date +%s)"
	if [[ -f "${GH_STAMP}" ]]; then
		last="$(<"${GH_STAMP}")"
		wait_for=$((GH_MIN_GAP_SECONDS - (now - last)))
		((wait_for > 0)) && sleep "${wait_for}"
	fi
	date +%s >"${GH_STAMP}"
}

# Run a gh command with the brief's back-off rules:
#   rate limiting (403/429/secondary limit): wait 60 s, doubling to 15 min;
#   transient states (mergeability still being computed, 5xx): retry after 10 s.
# Anything else fails at once. Never loops tightly.
gh_retry() {
	local backoff=60 transient_left=6 output status
	while true; do
		gh_gap
		status=0
		output="$("$@" 2>&1)" || status=$?
		if ((status == 0)); then
			[[ -n "${output}" ]] && printf '%s\n' "${output}"
			return 0
		fi
		if grep -qiE 'rate limit|HTTP 403|HTTP 429|submitted too quickly' <<<"${output}"; then
			note "rate limited; waiting ${backoff}s before retrying: $*"
			sleep "${backoff}"
			backoff=$((backoff * 2))
			((backoff > 900)) && backoff=900
			continue
		fi
		if ((transient_left > 0)) && grep -qiE 'not mergeable|mergeab|HTTP 50[0-9]|Base branch was modified|timeout|connection reset' <<<"${output}"; then
			transient_left=$((transient_left - 1))
			note "transient failure; retrying in 10s (${transient_left} tries left): $*"
			sleep 10
			continue
		fi
		printf '%s\n' "${output}" >&2
		return "${status}"
	done
}
