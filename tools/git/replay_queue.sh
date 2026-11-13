#!/usr/bin/env bash
# Publish the offline queue (ADR-0001): push every queued branch in order,
# open its pull request and merge it with a merge commit.
#
#   tools/git/replay_queue.sh            # replay everything
#   tools/git/replay_queue.sh --limit N  # replay at most N entries
#   tools/git/replay_queue.sh --dry-run  # print what would happen
#
# Safe to interrupt and run again: finished entries move to
# .git/pr-queue/done/ and branches that are already merged are skipped.
set -euo pipefail

# shellcheck source=tools/git/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

limit=0
dry_run=0
while (($# > 0)); do
	case "$1" in
		--limit) limit="${2:?--limit needs a number}" && shift 2 ;;
		--dry-run) dry_run=1 && shift ;;
		*) die "unknown argument: $1" ;;
	esac
done

run() {
	if ((dry_run)); then
		note "would run: $*"
	else
		"$@"
	fi
}

[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
[[ "$(git branch --show-current)" == "main" ]] || die "run this from main"
if ((!dry_run)); then
	blocker="$(publish_blocker)"
	[[ -z "${blocker}" ]] || die "not publishing: ${blocker}; see handoff/NEEDS_OWNER.md"
	"$(dirname "${BASH_SOURCE[0]}")/setup_auth.sh"
fi

# Remote main must either not exist yet (first publication: push the bootstrap
# commit, the one commit the brief allows directly on main) or be consistent
# with local main. After a partial replay origin/main ends in a merge commit
# that local main does not contain, so ancestry is the wrong test. What must
# hold is that origin/main has exactly the content of the newest commit both
# histories share: nothing else has been pushed there.
if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
	git fetch --quiet origin main
	shared="$(git merge-base origin/main main)" || die "origin/main and local main share no history"
	[[ "$(git rev-parse "origin/main^{tree}")" == "$(git rev-parse "${shared}^{tree}")" ]] ||
		die "origin/main contains changes that local main does not; refusing to continue"
else
	root_commit="$(git rev-list --max-parents=0 main | tail -n 1)"
	note "remote has no main yet; publishing bootstrap commit ${root_commit:0:7}"
	run git push --quiet origin "${root_commit}:refs/heads/main"
	run git fetch --quiet origin main
fi

mkdir -p "${QUEUE_DIR}/done"
processed=0
for entry in "${QUEUE_DIR}"/[0-9][0-9][0-9][0-9]-*; do
	[[ -e "${entry}" ]] || break
	if ((limit > 0 && processed >= limit)); then
		break
	fi
	base="$(basename "${entry}")"
	number="${base%%-*}"
	rest="${base#*-}"

	if [[ "${rest}" == TAG-*.tag ]]; then
		tag="${rest#TAG-}"
		tag="${tag%.tag}"
		note "[${number}] tag ${tag} on origin/main"
		run git tag --annotate "${tag}" --file "${entry}" origin/main
		run git push --quiet origin "refs/tags/${tag}"
		((dry_run)) || mv "${entry}" "${QUEUE_DIR}/done/"
		processed=$((processed + 1))
		continue
	fi

	branch="${rest%.md}"
	branch="${branch//__//}"
	git show-ref --verify --quiet "refs/heads/${branch}" || die "[${number}] local branch ${branch} is missing"
	title="$(sed -n '1p' "${entry}")"
	body_file="$(mktemp)"
	sed '1,2d' "${entry}" >"${body_file}"

	if ((!dry_run)) && git merge-base --is-ancestor "${branch}" origin/main; then
		note "[${number}] ${branch} is already in origin/main; skipping"
	else
		note "[${number}] ${branch}: ${title}"
		run git push --quiet -u origin "${branch}"
		if ((dry_run)) || [[ -z "$(gh pr list --head "${branch}" --state open --json number --jq '.[].number')" ]]; then
			run gh_retry gh pr create --base main --head "${branch}" --title "${title}" --body-file "${body_file}"
		fi
		run gh_retry gh pr merge "${branch}" --merge --delete-branch
		run git fetch --quiet origin main
	fi
	rm -f "${body_file}"
	if ((!dry_run)); then
		git show-ref --verify --quiet "refs/heads/${branch}" && git branch --quiet -D "${branch}"
		mv "${entry}" "${QUEUE_DIR}/done/"
	fi
	processed=$((processed + 1))
done

# Local main can only fast-forward onto the merge commits once every queued
# branch is merged; until then it stays on the newest queued tip.
if [[ "$(queue_length)" == "0" ]]; then
	run git pull --quiet --ff-only origin main
fi
note "replayed ${processed} entr$( ((processed == 1)) && printf 'y' || printf 'ies'); $(queue_length) left in the queue"
