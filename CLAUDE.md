# Contributor workflow

Rules for anyone, human or AI assistant, who changes this repository.

## Layout
- `game/` Godot project · `tools/` scripts · `tests/` automated checks ·
  `.github/workflows/` CI.
- `_local/` is an untracked, machine-local working folder (notes, downloads,
  tool installs, environment files). Nothing in it is ever committed.

## What belongs in the repository
- Generic, reusable code, configuration and tests only.
- Planning documents, design material, content data, environment files and
  keys stay in ignored paths. Code loads such material as data and refers to
  it generically.
- No file over 95 MB.

## Git flow
Every change goes through an issue, a branch and a pull request.
0. `tools/git/unit.sh issue <file|->` opens the issue for the task (line 1
   title, line 2 blank, then a short description and acceptance criteria).
   Known problems and open gaps get an issue too. Issues are public: generic
   technical wording only.
1. `tools/git/unit.sh start <type>/<short-slug>` branches from an up-to-date
   `main`. Types: `feat fix perf refactor docs test build chore art audio`.
2. Make one logical change and run the checks below.
3. Commit with Conventional Commits: imperative subject of 72 characters or
   fewer, and a body that says what and why when the change is not trivial.
   Every commit leaves the project importable.
4. Review the whole diff against `main` and fix the real problems found.
5. `tools/git/unit.sh finish <file|-> --review <file>` pushes the branch,
   opens the pull request (line 1 title, line 2 blank, then a body with a
   `CHECKED` section and `Closes #n`), posts the review file as a review
   comment (what was checked, problems found and how they were fixed) and
   then merges it with a merge commit.

- Merge commits only. Never squash, force-push or rewrite pushed history.
- No empty, duplicate or filler issues, reviews, commits or pull requests.
- Never commit to `main` directly.
- Leave at least 5 s between pull-request API calls and back off on rate
  limits; the scripts in `tools/git/` do both.
- If GitHub is unreachable, `unit.sh finish` queues the task locally and
  `tools/git/replay_queue.sh` publishes the queue later, in order.

## Checks
- `tests/tools/test_secret_scan.sh` and `tests/tools/test_git_queue.sh` pass.
- A report separates what was run (command and result) from what is assumed.

## Secrets
- `gh` and `git` read the GitHub credential from their own store or from
  `GH_TOKEN`. Never print, log, store or commit a credential, never put one
  in a URL, and never run a command that dumps the environment.
- `.gitignore` excludes key stores, `.env` files and signing material. The
  pre-commit hook (`tools/git/install_hooks.sh`) blocks staged credentials.
- If a secret is ever committed or printed, stop and have it revoked and
  rotated. Deleting it is not enough.

## Working copy
- Text files use LF line endings (`.gitattributes`).
- On a Windows-mounted drive git cannot see Unix file modes
  (`core.filemode=false`). Add every new script with `git add --chmod=+x`.
