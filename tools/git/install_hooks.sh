#!/usr/bin/env bash
# Point this clone's git hooks at the versioned ones in tools/git/hooks.
# Run once after cloning; safe to run again.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
git -C "${root}" config core.hooksPath tools/git/hooks
chmod +x "${root}"/tools/git/hooks/*
printf 'git hooks installed from tools/git/hooks\n'
