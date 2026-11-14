# Afterglow Road — standing orders for every session

Premium, paid, fully offline, single-player open-world post-apocalyptic survival
game for Windows, Linux, Android and iOS from one Godot 4 codebase (statically
typed GDScript). The owner directs and reviews; Claude does all the work.
The full brief lives in `docs/MASTER_BRIEF.md`. This file is the part that must
survive context loss. Obey it exactly.

## First thing in any new session (or on RESUME)
Read this file, `handoff/HANDOFF.md`, `handoff/NEEDS_OWNER.md`, run `git status`
and `git log -5`, then continue exactly where the handoff says.

## 1. Operating rules (non-negotiable)
1. **Autonomy.** Never ask the owner a question. Decide, record the decision in
   `docs/decisions/ADR-NNNN-title.md` (context, options, choice, consequences),
   continue. Things only a human can do (accounts, payments, phone play-tests,
   signing identities) go to `handoff/NEEDS_OWNER.md` as exact numbered steps;
   then carry on with other work.
2. **Truth.** Never claim something works unless it was run. Every report
   separates CHECKED (command + result) from ASSUMED. Say so when something
   cannot be observed here (visual quality, game feel, phone performance). For
   anything that changes (store rules, versions, licences, plugin
   compatibility) read the official source first and cite the URL. Never
   invent platform facts.
3. **Scope honesty.** An infeasible feature is never silently dropped or
   faked: write an ADR, ship the best feasible version, list the gap in
   `docs/KNOWN_GAPS.md`.
4. **Quality.** Ship quality only: no placeholder art called final, no stubs
   in main, no dead code. Statically typed GDScript everywhere.
5. **Stay inside `/mnt/d/afterglow-road`** (Windows `D:\afterglow-road`). It
   is the only copy of the project; never create another project folder.
   Only the project lives there: tools, caches and SDKs go under `~/tools`
   or `~/.local` in the WSL home (also on drive D). Never touch other repos,
   other folders or the Windows C: drive. Anything needing sudo goes to
   NEEDS_OWNER; use a user-level alternative meanwhile. Drive D does not
   store Unix file modes (`core.filemode=false`), so add every new script
   with `git add --chmod=+x`.
6. **Keep working until the owner types STOP.** When a milestone ends, start
   the next one immediately. Never wait for approval.
7. **Originality.** Everything is made from scratch in this repo. Outside
   material is limited to engine/tools and CC0 assets, each logged in
   `docs/ASSET_LICENSES.md` (source URL, licence, date) after reading the
   licence on the asset's own page. Never copy existing games, films, books,
   characters, logos, music, maps or names.
8. **Owner commands.** `STOP`, `RESUME`, `STATUS` (reply in 8 lines or fewer),
   `BUILD ANDROID` (debug APK built with Godot's Android export from this WSL
   machine, attached to a GitHub Release, plus 3 install steps), `BUILD PC`
   (Windows zip attached to a Release). No Expo/EAS anywhere.

## 3. GitHub and git protocol
- Remote: `https://github.com/Himkush1414/afterglow-road` (private).
- Credentials: fine-grained token in the environment variable `GH_TOKEN`. Use
  it only through `gh` and `git` (`gh auth setup-git`). NEVER print, echo,
  log, store in a file, place in a URL or commit it. Never run `env`,
  `printenv`, `set` or `gh auth token`. If it is missing or rejected: write
  NEEDS_OWNER, keep committing locally, push later (see "Offline queue").
- Identity: `user.email = <id>+<login>@users.noreply.github.com`,
  `user.name = <login>`, both from `gh api user`. If that call fails keep the
  existing git identity.
- Flow for EVERY unit of work:
  1. `git switch main && git pull --ff-only`
  2. `git switch -c <type>/<short-slug>`
  3. make the change; `tools/check.sh` must pass
  4. commit with Conventional Commits (`feat fix perf refactor docs test build
     chore art audio`); one logical change per commit; every commit leaves the
     project importable; imperative subject of 72 characters or fewer; add a
     body (what and why) when non-trivial
  5. `git push -u origin <branch>` immediately after each commit
  6. `gh pr create` (title; body with what, why, CHECKED/ASSUMED), then
     `gh pr merge --merge --delete-branch` (merge commits ONLY, never squash),
     then `git switch main && git pull --ff-only`
  7. never force-push or rewrite pushed history; never commit to main
     directly, except the bootstrap commit and the handoff commit at STOP.
- **Volume target:** at least 2,000 pushed commits AND 2,000 merged PRs by
  v1.0. One PR = one small, real, reviewable task (typically 1 to 5 commits).
  Count with `git rev-list --count main` and
  `gh pr list --state merged --limit 5000 --json number --jq length`.
  NEVER create empty, whitespace-only, duplicate, revert-and-redo or generated
  filler commits or PRs. If work seems to run out, split the remaining real
  work finer. A fake count is a failure.
- Rate limits: at least 5 s between consecutive `gh pr create`/`merge` calls.
  On HTTP 403/429 or "secondary rate limit": back off 60 s, double up to
  15 min, retry. Never loop tightly.
- Large files: GitHub rejects files over 100 MB; `tools/check.sh` guards at
  95 MB. Generators are the source of truth. Bulk generated data ships as
  versioned, checksummed zips on GitHub Releases, fetched by
  `tools/fetch_assets.sh`. Git LFS only if an ADR justifies it.
- CI: never on every PR (private-repo minutes are limited). Nightly headless
  import + tests on main, tag-triggered release builds, manual-dispatch iOS
  workflow. Concurrency groups with cancel-in-progress.
- Secrets hygiene: `.gitignore` covers `*.keystore *.jks .env *.p12
  *.mobileprovision google-services* export_credentials.cfg builds/`. The
  pre-commit hook scans staged diffs for token patterns and blocks the
  commit. If a secret is ever committed or printed: stop, tell the owner to
  revoke and rotate it; deleting it is not enough.
- Releases: tag `v0.<milestone>.0` at each milestone end with builds attached
  to the GitHub Release. `CHANGELOG.md` changes only at milestone end.

### Offline queue (when GitHub rejects the token or is unreachable)
See `docs/decisions/ADR-0001-offline-pr-queue.md`. Work continues in the same
small branches, stacked: each new branch starts at the tip of the previous
one, local `main` is fast-forwarded to that tip (no local merge commits), the
branch ref is kept, and the PR title/body is stored in `.git/pr-queue/`.
When auth works again run `tools/git/replay_queue.sh`, which pushes each
branch in order, opens its PR and merges it with a merge commit, honouring
the rate-limit rules. Then `git pull --ff-only` and return to the normal flow.

## 4. STOP and RESUME
On `STOP` (or "pause", "done for today") finish within 2 minutes:
1. Start nothing new. Finish only an edit that is under 30 s from done and
   passes `tools/check.sh --quick`.
2. Uncommitted work: quick check passes → commit normally; otherwise commit
   to `wip/<YYYY-MM-DD-HHMM>` with a `wip:` message and push it.
3. Push everything. List open PRs; do not merge failing ones.
4. Overwrite `handoff/HANDOFF.md` (80 lines max): current milestone, done
   today (10 lines max), in-progress item with the exact next 3 actions,
   branch/PR state, resume commands, known issues, pointer to NEEDS_OWNER.
   Update `handoff/STATUS.md` with counts (commits on main, merged PRs).
   Commit as `docs(handoff): ...` directly on main and push.
5. Reply in 8 lines or fewer: pushed yes/no, branch, counts, what is next,
   what the owner must do.
No long documentation work at STOP. On `RESUME` do the "first thing" above.

## 17. Reporting
Keep chat quiet while working: no step narration, no log dumps. Any message
to the owner is 12 lines max in this form:
`DONE / NOT DONE / OWNER MUST DO (numbered, exact steps, where to run each) /
CHECKED vs ASSUMED`. Message only at milestone ends, blockers, owner-needed
actions, STOP and STATUS.

## 18. Definition of done for 1.0
All milestones M0–M25 complete; checks green; no known crash or
save-corruption bug; 2,000+ real commits and 2,000+ merged PRs; signed
Android AAB ready for Play; Windows and Linux builds ready for Steam; iOS
workflow ready; all store documents written; every asset licence logged;
`docs/KNOWN_GAPS.md` honest and current; a final report listing what was
verified here and what only the owner can verify on real devices.

## Milestones (detail in `docs/MASTER_BRIEF.md` section 16)
M0 bootstrap · M1 design documents · M2 technical spikes · M3 core framework ·
M4 world generator · M5 the look · M6 vegetation · M7 player · M8 vitals,
items, inventory, crafting · M9 gathering · M10 camp building · M11 cooking
and farming · M12 vehicles · M13 settlements · M14 creatures and combat ·
M15 NPCs, quests, story · M16 audio · M17 UI/UX and accessibility ·
M18 optimisation · M19 Android pipeline · M20 PC pipeline · M21 iOS pipeline ·
M22 content completion · M23 QA hardening · M24 store package · M25 1.0 RC.
Each ends with: checks green, docs and KNOWN_GAPS updated, tag `v0.<N>.0`,
build attached to a GitHub Release.

## Where things live
`game/` Godot project (`src/ scenes/ content/ shaders/ ui/ addons/`) ·
`tools/` (`check.sh`, build scripts, `worldgen/ assetgen/ audiogen/
screenshot/ git/`) · `tests/` · `docs/` (`GDD/ story/ decisions/ art/ audio/
STORE/` plus `TOOLCHAIN.md OWNER_SETUP.md KNOWN_GAPS.md ASSET_LICENSES.md`) ·
`handoff/` (`HANDOFF.md STATUS.md NEEDS_OWNER.md`) · `builds/` (gitignored) ·
`.github/workflows/`. Pinned tool versions: `docs/TOOLCHAIN.md`.
