# Needs the owner

Things only a human can do. Open items first. Each item has exact steps and
says where to run them. An item is closed only when the fix was verified.

## Open

### 2. The GitHub repository is public; the brief says private

**Status:** OPEN since 2026-11-13, not blocking. Publication was held at
first and is now running, because your push routine (sent twice on
2026-11-13) tells every task to be pushed and merged on this remote. See the
addendum in `docs/decisions/ADR-0002-hold-pushes-while-remote-is-public.md`.

**What this means:** every file and every commit in this repository,
including the design documents and the commit author e-mail address, can be
read by anyone for as long as the repository is public.

**What was checked (2026-11-13):** `gh api repos/Himkush1414/afterglow-road`
→ `visibility=public`; an anonymous request → HTTP 200.

**If that is not what you want (1 minute, in a browser):**
1. Open <https://github.com/Himkush1414/afterglow-road/settings>.
2. *Danger Zone* → *Change repository visibility* → *Change to private*.
3. Nothing else; work continues unchanged.

**The first commit** (`CLAUDE.md` only) was pushed before you set the commit
identity and shows the previous git identity of this machine, another
personal e-mail address. Pushed history is never rewritten here. If you want
that address gone from history, type `rewrite bootstrap commit` (a one-time
force-push of `main`).

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
