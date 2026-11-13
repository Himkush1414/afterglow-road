# ADR-0001: Offline pull-request queue while GitHub is unavailable

- Status: accepted
- Date: 2026-11-13

## Context
The brief requires every unit of work to be a small branch that is pushed,
opened as a pull request and merged with a merge commit, and it sets a target
of 2,000 real merged pull requests. On the first day `gh api user` returned
`HTTP 401 Bad credentials` for the token in `GH_TOKEN` (see
`handoff/NEEDS_OWNER.md` item 1). The brief's fallback is "keep committing
locally, and push later", but it does not say how the per-task pull requests
survive a period without GitHub.

## Options
1. **Commit straight to local `main`.** Simple, but the work can then only be
   pushed as one large update. Every task done offline would lose its pull
   request, and the history would no longer show one reviewable unit per PR.
2. **Local merge commits** (`git merge --no-ff` into local `main`). Keeps the
   shape locally, but GitHub cannot open a pull request for commits that are
   already in `main`, and replaying the branches later would create a second
   set of merge commits and force a rewrite of local history.
3. **Stacked branch queue.** Each task is a branch that starts at the tip of
   the previous task's branch. Local `main` is only ever fast-forwarded to the
   newest tip, so it contains no merge commits. The branch refs are kept, and
   each task's PR title and body are stored in `.git/pr-queue/`. When GitHub
   works again the branches are pushed one at a time, in order, and each gets
   a real pull request merged with a merge commit.

## Choice
Option 3.

## Consequences
- Each offline task still becomes its own pull request with its own
  description; nothing is batched and nothing is invented afterwards. The
  pull requests are merely opened later than the work was done.
- After the replay, remote `main` is a chain of merge commits whose second
  parents are the queued branch tips. Local `main` is an ancestor of that
  chain, so `git pull --ff-only` succeeds and no history is rewritten.
- The queue lives inside `.git/`, so it is never committed and never pushed.
  It is lost if the working copy is deleted; the branches and commits would
  be lost with it in that case anyway.
- Replaying N tasks takes roughly N × 15 s because of the mandatory 5 s gaps
  between `gh pr create` and `gh pr merge` calls.
- Tasks are stacked, so a queued branch cannot be dropped or reordered
  without rebasing the ones after it. Mistakes found while offline are fixed
  by a new task on top, exactly as they would be online.
- Tags and Releases cannot be published offline. Milestone tags are created
  locally and pushed during the replay; Release assets are built into
  `builds/` and attached once GitHub is reachable.
- `tools/git/unit.sh` hides the difference: `start` and `finish` behave the
  same in both modes, and `finish` switches back to the online flow by itself
  once the queue is empty and authentication succeeds.
