# Needs the owner

Things only a human can do. Newest first. Each item has exact steps and says
where to run them. Remove an item only when it is verified fixed.

## 1. GitHub rejects the token in `GH_TOKEN` (blocks every push, PR and Release)

**Status:** OPEN since 2026-11-13. Work continues locally; nothing is lost.

**What was checked (2026-11-13, in WSL, in `~/projects/afterglow-road`):**
- `gh api user` → `HTTP 401 Bad credentials` (twice).
- `gh api repos/Himkush1414/afterglow-road` → `HTTP 401 Bad credentials`.
- The variable is set and is 107 characters long. Without printing it, shape
  tests show it starts with `ghp_` and contains two more underscores
  (segments of 39, 26 and 36 characters).
- The brief describes a *fine-grained* token. Fine-grained tokens start with
  `github_pat_`. A classic token is `ghp_` followed by 36 characters (40 in
  total). The value in the variable matches neither, so it is most likely a
  paste accident (two things joined, or the wrong value copied) or a token
  that has since been revoked or expired.

**Fix (about 3 minutes):**
1. In a browser, signed in as the account that owns the repo, open
   <https://github.com/settings/personal-access-tokens> → *Generate new
   token* (fine-grained).
2. Resource owner: `Himkush1414`. Repository access: *Only select
   repositories* → `afterglow-road`.
3. Repository permissions: **Contents: Read and write**, **Pull requests:
   Read and write**, **Workflows: Read and write** (Metadata: Read is added
   automatically). Generate, then copy the token once. It must start with
   `github_pat_`.
4. In the WSL terminal, leave Claude Code (`/exit`), then run the two lines
   below. The first line reads the token without showing it or saving it in
   shell history; paste the token and press Enter.
   ```bash
   read -rs GH_TOKEN && export GH_TOKEN
   cd ~/projects/afterglow-road && claude
   ```
5. In Claude Code type `RESUME`. The session verifies the token with
   `gh api user`, then runs `tools/git/replay_queue.sh`, which pushes the
   locally queued branches in order and opens and merges one pull request for
   each.
6. Revoke the old token on the same GitHub page if it is still listed.

**Until then:** every unit of work is still a small branch with its own
commits, queued for its own pull request (see
`docs/decisions/ADR-0001-offline-pr-queue.md`). `BUILD ANDROID` and
`BUILD PC` can build locally into `builds/` but cannot attach files to a
GitHub Release.

**Side note on commit identity:** because `gh api user` fails, commits use
the existing git identity of this machine, as the brief instructs. If the
GitHub account has "Block command line pushes that expose my email" switched
on, the first push may be refused with error `GH007`; that case is handled
at replay time by reporting it here, not by rewriting history.
