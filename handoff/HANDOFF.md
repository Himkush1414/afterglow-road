# Handoff — 2026-11-13 11:46 UTC (STOP)

## Where we are
Milestone **M0 Bootstrap**, about one third done. `main` is clean and equal
to the remote. No open PRs, no wip branch, nothing queued.

## Done today
- Repo initialised, `CLAUDE.md` (standing orders), `docs/MASTER_BRIEF.md`.
- GitHub access fixed: gh is logged in as `Himkush1414` with the fine-grained
  token; commit identity set as the owner instructed.
- `tools/git/unit.sh` (one branch = one PR), `replay_queue.sh`, `setup_auth.sh`,
  with an integration test (33 checks) — ADR-0001.
- ADR-0002: repository is PUBLIC; hold lifted on the owner's push routine.
- `.gitignore`, `.gitattributes`, secret scanner + pre-commit hook + test.
- 14 PRs opened and merged with merge commits (#1–#14).
- Godot 4.7.2-stable editor and export templates downloaded and
  SHA-512-verified in `~/tools/godot/4.7.2-stable/downloads/` (not unpacked).
- Reference repos shallow-cloned to `~/reference/` (ponytail, gstack, ruflo).
  Nothing from them was installed, run or read yet.

## Not done (owner requests still open, in this order)
1. **15-minute GDD session** (arrived together with STOP, not started):
   a) re-read `docs/MASTER_BRIEF.md`, list gaps and weak spots, fix in docs;
   b) `docs/GDD/` one doc per PR, exhaustive with tables and numbers:
      `00_vision`, `01_world_bible`, `02_story_bible`, `04_survival_systems`,
      `05_items_crafting`, `07_vehicles`, `08_creatures` (one sheet per
      species). Everything planned lives in `docs/GDD/`.
2. **Helper tools**: install ponytail, gstack, ruflo at user level
   (`~/.local`) following each README; read every install script first; run
   with `GH_TOKEN` unset; skip and log in NEEDS_OWNER anything needing sudo
   or a secret; test each with its simplest command; write
   `docs/reference/NOTES.md` (what, how installed, how used, licence). Never
   copy their code; never commit them. Then reply to the owner in 5 lines.
3. **Record new owner rules in `CLAUDE.md`** (one PR): commit identity
   `Himkush1414 <light.dark14143@gmail.com>`; gh stored login replaces the
   stale `GH_TOKEN`; push routine with the final check (`git ls-remote origin
   main` = `git rev-parse main`); storage rule (D drive only, never
   `/mnt/c`; real free space is `df -h /mnt/d`, 68 GB on 2026-11-13).

## Exact next 3 actions
1. `tools/git/unit.sh start docs/claude-md-owner-rules` → item 3 above →
   `tools/git/unit.sh finish -` (title line, blank line, body with CHECKED).
2. Item 1a, then `docs/GDD/00_vision.md` as its own PR; continue through the
   GDD list, one PR each.
3. Item 2 (helper tools), then resume M0: docs skeleton, README + licence
   notice, unpack Godot, `docs/TOOLCHAIN.md`, Godot project, `tools/check.sh`.

## Remaining M0 list
docs skeleton (`KNOWN_GAPS`, `ASSET_LICENSES`, `OWNER_SETUP`, `STORE/`) ·
README + all-rights-reserved notice · toolchain install script with pinned
versions and checksums (Godot, JDK 17, Android SDK, GUT, gdtoolkit venv,
Blender) · Godot project in `game/` · `tools/check.sh` (+ `--quick`) running
the two shell tests · screenshot harness · CI workflows · ADR on Release
asset/LFS limits · tag `v0.0.0`.

## Resume commands
```bash
cd /mnt/d/afterglow-road
git status && git log --oneline -5
tools/git/unit.sh status          # expect: mode online, blocker none
tests/tools/test_git_queue.sh && tests/tools/test_secret_scan.sh
```

## Known issues
- The session's `GH_TOKEN` variable is stale (HTTP 401). Scripts drop it
  automatically; in a raw shell run `unset GH_TOKEN` before `gh`/`git push`.
- `tools/check.sh` does not exist yet; until it does, run the two tests above.
- A pre-existing `~/toolchain` (JDK 17.0.13, Android SDK 36/37, NDK 27.1) is
  on this machine and exported as `JAVA_HOME`/`ANDROID_HOME`; decide in the
  toolchain ADR whether to reuse it or install under `~/tools`.
- GitHub shows the merge commits as authored by the account's profile name;
  task commits carry the configured identity.

## Owner
See `handoff/NEEDS_OWNER.md`: item 2 (repository is public — make it private
if that was not intended) and item 3 (revoke the unused tokens).
