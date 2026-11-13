# ADR-0002: Hold publication while the GitHub repository is public

- Status: accepted; hold lifted on 2026-11-13 by owner instruction (see the addendum)
- Date: 2026-11-13

## Context
The brief describes the remote as "private, empty, created by the owner" and
the project as a premium paid game under an all-rights-reserved notice. On
2026-11-13, after the owner supplied a working token, these were checked:

- `gh api repos/Himkush1414/afterglow-road` → `private=false`,
  `visibility=public`.
- An anonymous request to the same API endpoint returned HTTP 200 (a private
  repository returns 404 to anonymous callers).

The bootstrap commit had already been pushed as `main` during the owner's
requested push test, before the consequence was thought through. It contains
only `CLAUDE.md`, but its author field carries the git identity this machine
had at the time, which is a personal e-mail address. That one commit is
therefore publicly readable until the repository is made private.

The token is fine-grained (Contents, Pull requests, Workflows) and cannot
change repository visibility. Changing it is an owner decision in any case.

## Options
1. **Publish anyway**, following "push after every commit" literally. Every
   design document, generator and source file of a paid product would become
   public. Publication cannot be undone: public repositories can be cloned,
   forked, cached and indexed within minutes.
2. **Hold publication, keep working.** Continue in the stacked offline queue
   of ADR-0001 and publish the moment the repository is private. Costs
   nothing but a delay; every task still gets its own pull request.
3. **Stop all work** until the owner reacts. Wastes the session for a problem
   that does not block local work.

## Choice
Option 2. `tools/git/lib.sh` gains `publish_blocker`, which reports a reason
whenever gh cannot authenticate or the remote is public. `unit.sh` treats any
blocker as offline mode and `replay_queue.sh` refuses to run. The check is
live, so no session restart is needed after the owner flips the visibility.

The owner can state that a public repository is intended. That is recorded
with `git config afterglow.allowPublicRemote true` (local to this clone),
which removes the blocker.

## Consequences
- The owner's stated expectation (private source) is honoured even though the
  remote does not match it; the irreversible action is the one that waits.
- "Push after every commit" is suspended only while the blocker exists. The
  queue preserves the one-task-one-PR history for later.
- The already-pushed bootstrap commit is not rewritten: the brief forbids
  force-pushing and rewriting pushed history. Making the repository private
  hides it. The commits made after it and before this ADR were still local,
  so their author field was re-written to the account's GitHub no-reply
  address before they are ever pushed.
- `handoff/NEEDS_OWNER.md` carries the exact steps for the owner.
- One extra API call (`GET /repos/{owner}/{repo}`) per `unit.sh` invocation.

## Addendum, 2026-11-13: the owner instructed publication

The finding above was reported to the owner in the session, with the two
ways to lift the hold. The owner then sent two further instructions. Neither
changed the repository's visibility (re-checked: `visibility=public`), and
both contain a "push routine for every task" that requires each task to be
pushed, opened as a pull request against this remote and merged, and that
ends with a check that `git ls-remote origin main` equals local `main`. The
same messages set the commit identity explicitly (`user.name` and
`user.email` as given by the owner).

Decision: the hold is lifted with `git config afterglow.allowPublicRemote
true`. The irreversible step was withheld until the owner had the facts; the
owner has since directed publication twice, and repeating the objection would
put a description in the brief ("private") above direct instructions.

What stays true and stays visible:
- Everything pushed is publicly readable for as long as the repository is
  public. `handoff/NEEDS_OWNER.md` keeps the one-minute steps to make it
  private; doing so at any time needs no change on this side.
- The mechanism remains in place. Removing the setting
  (`git config --unset afterglow.allowPublicRemote`) restores the hold.
- No secret, keystore, token or personal file is ever committed, public or
  not; the secret scan and `.gitignore` do not depend on visibility.
- Unpushed commits were re-authored to the owner's chosen identity before
  publication. The bootstrap commit, pushed earlier, keeps the machine's
  previous identity because pushed history is never rewritten.
