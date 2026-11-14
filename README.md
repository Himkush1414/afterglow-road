# afterglow-road

A first-person, open-world survival game for desktop and mobile, built with
[Godot 4](https://godotengine.org/) in statically typed GDScript.

**Status:** early development. This repository holds the engine-side code,
tools and tests. Game content (art, audio, data, text) is not part of the
repository.

## Layout

| Path | Content |
|---|---|
| `game/` | Godot project: scripts, shaders, node-only scenes, UI (not added yet) |
| `tools/` | Build, check and git helper scripts |
| `tests/` | Automated checks for the tools |
| `.github/workflows/` | CI (not added yet) |

## Working on the repository

Every change goes through a small branch and a pull request that is merged
with a merge commit. The helper scripts do this in one step each:

```bash
tools/git/install_hooks.sh                 # once per clone: enable the pre-commit secret scan
tools/git/unit.sh start <type>/<slug>      # branch from an up-to-date main
# ... make one logical change, commit with a Conventional Commit message ...
tools/git/unit.sh finish <file|->          # push, open the pull request, merge
```

Checks:

```bash
tests/tools/test_secret_scan.sh
tests/tools/test_git_queue.sh
```

The full contributor rules are in [`CLAUDE.md`](CLAUDE.md).

## Licence

No licence is granted at this time. All rights reserved.
The Godot Engine is used under the MIT licence.
