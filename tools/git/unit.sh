#!/usr/bin/env bash
# One unit of work = one small branch = one pull request.
#
#   tools/git/unit.sh start <type>/<short-slug>
#   tools/git/unit.sh finish <file|->     # line 1: PR title, line 2: blank, rest: PR body
#   tools/git/unit.sh status
#
# Online (token accepted, queue empty) this is the flow from CLAUDE.md
# section 3: push, open the PR, merge it with a merge commit, pull main.
# Offline it queues the PR as described in ADR-0001 and fast-forwards local
# main, so work never stops and no task loses its own pull request.
set -euo pipefail

# shellcheck source=tools/git/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALLOWED_TYPES='feat|fix|perf|refactor|docs|test|build|chore|art|audio'

# Temporary files are tracked globally so the EXIT trap can still see them
# after the function that created them has returned.
TEMP_FILES=()
cleanup() {
	((${#TEMP_FILES[@]} > 0)) && rm -f "${TEMP_FILES[@]}"
	return 0
}
trap cleanup EXIT

usage() {
	sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

mode() {
	if [[ "$(queue_length)" != "0" ]]; then
		printf 'offline\n'
	elif gh_online; then
		printf 'online\n'
	else
		printf 'offline\n'
	fi
}

cmd_start() {
	local branch="${1:-}"
	[[ "${branch}" =~ ^(${ALLOWED_TYPES})/[a-z0-9][a-z0-9.-]*$ ]] ||
		die "branch must look like <type>/<short-slug> with type in ${ALLOWED_TYPES}"
	git show-ref --verify --quiet "refs/heads/${branch}" && die "branch ${branch} already exists"
	git switch --quiet main
	if [[ "$(mode)" == "online" ]]; then
		git pull --quiet --ff-only
	fi
	git switch --quiet -c "${branch}"
	note "started ${branch}"
}

cmd_finish() {
	local source_file="${1:-}" branch title body_file ahead number entry
	[[ -n "${source_file}" ]] || usage
	branch="$(git branch --show-current)"
	[[ -n "${branch}" && "${branch}" != "main" ]] || die "finish must run on a task branch"
	[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean; commit first"
	ahead="$(git rev-list --count "main..${branch}")"
	((ahead > 0)) || die "${branch} has no commits that main lacks"

	body_file="$(mktemp)"
	TEMP_FILES+=("${body_file}" "${body_file}.all")
	if [[ "${source_file}" == "-" ]]; then
		cat >"${body_file}.all"
	else
		cp "${source_file}" "${body_file}.all"
	fi
	title="$(sed -n '1p' "${body_file}.all")"
	sed '1,2d' "${body_file}.all" >"${body_file}"
	[[ -n "${title}" ]] || die "PR title (first line) is empty"
	((${#title} <= 72)) || die "PR title is longer than 72 characters"
	[[ -s "${body_file}" ]] || die "PR body is empty"
	grep -q 'CHECKED' "${body_file}" || die "PR body must contain a CHECKED section"

	if [[ "$(mode)" == "online" ]]; then
		git push --quiet -u origin "${branch}"
		gh_retry gh pr create --base main --head "${branch}" --title "${title}" --body-file "${body_file}"
		gh_retry gh pr merge "${branch}" --merge --delete-branch
		git switch --quiet main
		git pull --quiet --ff-only
		git show-ref --verify --quiet "refs/heads/${branch}" && git branch --quiet -d "${branch}"
		note "merged ${branch} (${ahead} commit(s))"
	else
		mkdir -p "${QUEUE_DIR}"
		number="$(queue_next_number)"
		entry="${QUEUE_DIR}/${number}-${branch//\//__}.md"
		{
			printf '%s\n\n' "${title}"
			cat "${body_file}"
		} >"${entry}"
		git switch --quiet main
		git merge --quiet --ff-only "${branch}"
		note "queued ${branch} as ${number} (${ahead} commit(s)); $(queue_length) task(s) waiting for GitHub"
	fi
}

cmd_status() {
	printf 'mode: %s\n' "$(mode)"
	printf 'queued tasks: %s\n' "$(queue_length)"
	printf 'commits on main: %s\n' "$(git rev-list --count main)"
	printf 'branch: %s\n' "$(git branch --show-current)"
}

case "${1:-}" in
	start) shift && cmd_start "$@" ;;
	finish) shift && cmd_finish "$@" ;;
	status) cmd_status ;;
	*) usage ;;
esac
