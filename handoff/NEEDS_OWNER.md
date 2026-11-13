# Needs the owner

Things only a human can do. Open items first. Each item has exact steps and
says where to run them. An item is closed only when the fix was verified.

## Open

### 2. The GitHub repository is public; the brief says private

**Status:** OPEN since 2026-11-13. Work continues locally; publication is on
hold (see `docs/decisions/ADR-0002-hold-pushes-while-remote-is-public.md`).

**What was checked (2026-11-13):**
- `gh api repos/Himkush1414/afterglow-road` → `private=false`,
  `visibility=public`.
- An anonymous request to the same endpoint → HTTP 200 (private repositories
  answer 404).
- The only thing pushed so far is the bootstrap commit (`CLAUDE.md`). Its
  author field shows the git identity this machine had at that moment, a
  personal e-mail address, and it is publicly readable right now. All later
  commits use the account's GitHub no-reply address.

**Fix (1 minute, in a browser):**
1. Open <https://github.com/Himkush1414/afterglow-road/settings>.
2. Scroll to *Danger Zone* → *Change repository visibility* → *Change to
   private* and confirm.
3. Nothing else. The next finished task notices the change and publishes the
   queued branches in order, one pull request each. Typing `RESUME` or
   `STATUS` works too.

**If a public repository is what you want:** type `public is intended` in
Claude Code. The hold is then lifted with
`git config afterglow.allowPublicRemote true` and everything is published.

**About the exposed e-mail address:** making the repository private hides it.
The pushed commit is not rewritten, because the brief forbids force-pushes.
If you want the address removed from history as well, type
`rewrite bootstrap commit`; that is a one-time force-push of `main` done
before anything else is published.

### 3. Revoke the two tokens that are no longer used

**Status:** OPEN since 2026-11-13. Not blocking.

1. Open <https://github.com/settings/tokens> (classic tokens).
2. Delete the `ghp_…` token that was pasted into the chat on 2026-11-13. It
   lacked the `read:org` scope, was never stored and is not used.
3. If the 107-character value from the original `GH_TOKEN` variable was ever
   a real token, delete it as well.

The token in use is the fine-grained one pasted into the chat on 2026-11-13.
It is stored only in gh's own file `~/.config/gh/hosts.yml`, outside the
project. Chat transcripts stay on this machine under `~/.claude/`; if anyone
else can read that folder, create a fresh fine-grained token later and log in
again with `gh auth login --with-token`.

## Closed

### 1. GitHub rejected the token in `GH_TOKEN`

**Closed 2026-11-13.** The original variable (107 characters, starting with
`ghp_`) is rejected with `HTTP 401 Bad credentials`. The owner supplied a
fine-grained token; `gh auth login --with-token` succeeded and these passed:
`gh api user` → `Himkush1414`; repository readable with `push=true`; push of
`main`; push and deletion of a `test/token-check` branch.

The stale variable is still present in the environment of sessions started
before the fix. The scripts in `tools/git/` drop it automatically when it is
rejected and gh's stored login works. To get rid of it for good, start new
sessions from a terminal where `GH_TOKEN` is not exported.
