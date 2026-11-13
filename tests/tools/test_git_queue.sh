#!/usr/bin/env bash
# Integration test for tools/git/unit.sh and tools/git/replay_queue.sh.
#
# Runs entirely on this machine: a bare repository plays github.com and
# tests/tools/fakes/gh plays the GitHub CLI. Nothing touches the network or
# the real project history.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${here}/../.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

export FAKE_GH_STATE="${sandbox}/gh-state"
export FAKE_GH_REMOTE="${sandbox}/remote.git"
export FAKE_GH_VISIBILITY="public"
export FAKE_GH_AUTH="ok"
export AFTERGLOW_TEST_GH_GAP_SECONDS=0
export PATH="${here}/fakes:${PATH}"
unset GH_TOKEN
# Keep the sandbox independent of the developer's own git configuration.
export GIT_CONFIG_GLOBAL="${sandbox}/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name "queue test"
git config --global user.email "queue-test@example.invalid"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

failures=0
check() {
	local description="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		printf '  ok    %s\n' "${description}"
	else
		printf '  FAIL  %s\n' "${description}"
		failures=$((failures + 1))
	fi
}
equals() { [[ "$1" == "$2" ]]; }

work="${sandbox}/work"
git init --quiet --bare "${FAKE_GH_REMOTE}"
git init --quiet "${work}"
cd "${work}"
mkdir -p tools/git
cp "${project_root}"/tools/git/*.sh tools/git/
git add -A
git commit --quiet -m "chore: bootstrap"
git remote add origin "${FAKE_GH_REMOTE}"

unit() { tools/git/unit.sh "$@" 2>&1; }
queue_count() { find .git/pr-queue -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*' 2>/dev/null | wc -l; }
remote_has() { git -C "${FAKE_GH_REMOTE}" show-ref --verify --quiet "refs/heads/$1"; }
remote_main() { git -C "${FAKE_GH_REMOTE}" rev-parse main; }
merges_on_remote() { git -C "${FAKE_GH_REMOTE}" rev-list --merges --count main; }

# Make a task with the given number of commits and finish it.
task() {
	local branch="$1" commits="$2" index
	unit start "${branch}" >/dev/null
	for ((index = 1; index <= commits; index++)); do
		printf '%s %d\n' "${branch}" "${index}" >>"notes-${branch//\//-}.txt"
		git add -A
		git commit --quiet -m "docs: ${branch} step ${index}"
	done
	unit finish - <<BODY
docs: ${branch}

## What
Test task ${branch}.

## CHECKED
- nothing, this is a fixture
BODY
}

printf 'public remote: tasks are queued, nothing is pushed\n'
task docs/alpha 1 >/dev/null
task docs/beta 2 >/dev/null
check "two tasks queued" equals "$(queue_count)" "2"
check "remote still has no main" bash -c "! git -C '${FAKE_GH_REMOTE}' show-ref --verify --quiet refs/heads/main"
check "local main is the newest task tip" equals "$(git rev-parse main)" "$(git rev-parse docs/beta)"
check "local main has no merge commits" equals "$(git rev-list --merges --count main)" "0"
check "replay refuses while the remote is public" bash -c "! tools/git/replay_queue.sh"

printf 'rejected credential: tasks are queued\n'
FAKE_GH_AUTH=bad task docs/gamma 1 >/dev/null
check "three tasks queued" equals "$(queue_count)" "3"

printf 'private remote: partial replay\n'
export FAKE_GH_VISIBILITY="private"
tools/git/replay_queue.sh --limit 1 >/dev/null 2>&1
check "bootstrap commit became remote main's root" equals \
	"$(git -C "${FAKE_GH_REMOTE}" rev-list --max-parents=0 main)" "$(git rev-list --max-parents=0 main)"
check "one merge commit on the remote" equals "$(merges_on_remote)" "1"
check "two tasks still queued" equals "$(queue_count)" "2"
check "merged branch removed from the remote" bash -c "! git -C '${FAKE_GH_REMOTE}' show-ref --verify --quiet refs/heads/docs/alpha"
check "local main untouched by the partial replay" equals "$(git rev-parse main)" "$(git rev-parse docs/gamma)"

printf 'private remote: finishing a task drains the backlog\n'
task docs/delta 1 >/dev/null
check "queue is empty" equals "$(queue_count)" "0"
check "four merge commits on the remote" equals "$(merges_on_remote)" "4"
check "local main equals remote main" equals "$(git rev-parse main)" "$(remote_main)"
check "every task commit is on main (1 bootstrap + 5 task + 4 merges)" equals "$(git rev-list --count main)" "10"
check "no task branches left locally" equals "$(git branch --list | grep -vc '^\* main$')" "0"
check "only main is left on the remote" equals "$(git -C "${FAKE_GH_REMOTE}" for-each-ref --format='%(refname)' refs/heads | tr '\n' ' ')" "refs/heads/main "
check "pull requests were merged in queue order" equals "$(tr '\n' ' ' <"${FAKE_GH_STATE}/merged")" "1 2 3 4 "
check "first PR title came from the queue entry" equals "$(cat "${FAKE_GH_STATE}/title-1")" "docs: docs/alpha"

printf 'private remote, empty queue: the normal online flow\n'
task docs/epsilon 2 >/dev/null
check "merged at once" equals "$(merges_on_remote)" "5"
check "queue stays empty" equals "$(queue_count)" "0"
check "local main equals remote main" equals "$(git rev-parse main)" "$(remote_main)"
check "merge commit has the task tip as second parent" equals \
	"$(git log -1 --format=%s main^2)" "docs: docs/epsilon step 2"

printf 'commits by another author are not published\n'
unit start docs/eta >/dev/null
printf 'eta\n' >notes-eta.txt
git add -A
git -c user.name="someone else" -c user.email="else@example.invalid" commit --quiet -m "docs: eta by the wrong author"
finish_output="$(
	unit finish - <<'BODY' || true
docs: eta

## What
Fixture authored by the wrong identity.

## CHECKED
- nothing, this is a fixture
BODY
)"
check "finish reports the authorship problem" grep -q "are not authored by queue test" <<<"${finish_output}"
check "nothing new was merged" equals "$(merges_on_remote)" "5"
check "the branch was not pushed" bash -c "! git -C '${FAKE_GH_REMOTE}' show-ref --verify --quiet refs/heads/docs/eta"
check "the task stays queued" equals "$(queue_count)" "1"
git commit --quiet --amend --no-edit --reset-author
git branch --quiet --force docs/eta main
tools/git/replay_queue.sh >/dev/null 2>&1
check "published once the author is corrected" equals "$(merges_on_remote)" "6"
check "local main equals remote main" equals "$(git rev-parse main)" "$(remote_main)"

printf 'milestone tag entries\n'
printf 'M0 bootstrap\n' >".git/pr-queue/$(printf '%04d' 99)-TAG-v0.0.0.tag"
tools/git/replay_queue.sh >/dev/null 2>&1
check "annotated tag exists on the remote" equals \
	"$(git -C "${FAKE_GH_REMOTE}" cat-file -t v0.0.0)" "tag"
check "tag points at remote main" equals \
	"$(git -C "${FAKE_GH_REMOTE}" rev-parse 'v0.0.0^{commit}')" "$(remote_main)"

printf 'foreign commits on the remote are detected\n'
intruder="${sandbox}/intruder"
git clone --quiet "${FAKE_GH_REMOTE}" "${intruder}"
printf 'surprise\n' >"${intruder}/surprise.txt"
git -C "${intruder}" add -A
git -C "${intruder}" commit --quiet -m "docs: pushed from elsewhere"
git -C "${intruder}" push --quiet origin main
FAKE_GH_VISIBILITY=public task docs/zeta 1 >/dev/null
check "replay refuses to continue" bash -c "! tools/git/replay_queue.sh"
check "the task stays queued" equals "$(queue_count)" "1"

printf '\n'
if ((failures > 0)); then
	printf '%d check(s) failed\n' "${failures}"
	exit 1
fi
printf 'all git queue checks passed\n'
