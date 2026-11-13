#!/usr/bin/env bash
# One unit of work = one small branch = one pull request.
#
#   tools/git/unit.sh start <type>/<short-slug>
#   tools/git/unit.sh finish <file|->     # line 1: PR title, line 2: blank, rest: PR body
#   tools/git/unit.sh status
#
# finish always records the task in the queue of ADR-0001 and fast-forwards
# local main. If nothing blocks publication it then drains the queue: each
# queued branch is pushed, gets its pull request and is merged with a merge
# commit (CLAUDE.md section 3). With an empty queue that is exactly the normal
# online flow; after an offline period it catches up a batch at a time.
set -euo pipefail

# shellcheck source=tools/git/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALLOWED_TYPES='feat|fix|perf|refactor|docs|test|build|chore|art|audio'

# Most queue entries one finish call publishes (about 15 s each because of the
# mandatory gaps between pull-request API calls).
DRAIN_BATCH=15

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
	if [[ "$(queue_length)" == "0" && -z "$(publish_blocker)" ]]; then
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
		git pull --quiet --ff-only origin main
	fi
	git switch --quiet -c "${branch}"
	note "started ${branch}"
}

cmd_finish() {
	local source_file="${1:-}" branch title body_file ahead number entry blocker
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

	mkdir -p "${QUEUE_DIR}"
	number="$(queue_next_number)"
	entry="${QUEUE_DIR}/${number}-${branch//\//__}.md"
	{
		printf '%s\n\n' "${title}"
		cat "${body_file}"
	} >"${entry}"
	git switch --quiet main
	git merge --quiet --ff-only "${branch}"

	blocker="$(publish_blocker)"
	if [[ -n "${blocker}" ]]; then
		note "queued ${branch} as ${number} (${ahead} commit(s)); $(queue_length) task(s) waiting: ${blocker}"
		return 0
	fi
	"$(dirname "${BASH_SOURCE[0]}")/replay_queue.sh" --limit "${DRAIN_BATCH}"
}

cmd_status() {
	local blocker
	blocker="$(publish_blocker)"
	printf 'mode: %s\n' "$(mode)"
	printf 'publish blocker: %s\n' "${blocker:-none}"
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
