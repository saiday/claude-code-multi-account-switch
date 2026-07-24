# ccswitch — macOS Claude Code account switcher

Date: 2026-07-22
Status: ready-for-agent
Chain: grill-with-docs → **to-spec** → to-tickets → implement → code-review

## Problem Statement

I use several Claude Code accounts (personal Pro/Max, a work org seat, another
org). To move between them today I run `/login` and go through the browser OAuth
flow every single time. It is slow, it interrupts whatever I was doing, and there
is no way to keep more than one account "ready" on the machine. I want to save my
accounts once and flip between them with a single command.

## Solution

A single-file bash command, `ccswitch`, for macOS. I log into each account once
and run `ccswitch add` to save it into a numbered slot. From then on
`ccswitch switch <slot|email|alias>` makes that account the active Claude Code
login — no browser, no re-auth. `ccswitch list` shows what I've saved and which
one is live. A running Claude Code session picks up the change within about 30
seconds, or immediately on restart.

The switch is safe by construction: it coordinates with Claude Code's own token
refresh so a switch never silently reverts, it rolls back on failure, and it
re-captures the account I'm leaving so that account's saved credential never goes
stale and locks me out later.

## User Stories

1. As a multi-account Claude Code user, I want to save my currently-logged-in
   account into a slot, so that I can return to it later without re-authenticating.
2. As a user, I want each saved account to record its email and organization, so
   that I can tell a personal seat apart from an org seat of the same email.
3. As a user, I want to give a slot a human alias (e.g. `work`), so that I can
   switch by a name I remember instead of a number.
4. As a user, I want to switch the active account by slot number, so that I can
   act quickly off what `ccswitch list` shows.
5. As a user, I want to switch by email, so that I can switch without looking up
   the slot number.
6. As a user, I want to switch by alias, so that daily switching reads naturally.
7. As a user, I want an ambiguous email (one that matches two orgs) to error and
   list the candidate slots, so that I never switch into the wrong seat by accident.
8. As a user, I want `ccswitch list` to show every slot with its email, org,
   alias, and an active marker, so that I can see my accounts at a glance.
9. As a user, I want `ccswitch status` to show the currently active account, so
   that I can confirm which login is live before I start work.
10. As a user, I want the active account to be detected from the live login state
    rather than a stored pointer, so that the "active" marker is never wrong even
    if I logged in or switched by other means.
11. As a user, I want a switch to preserve my MCP server logins (Slack, Figma,
    Notion, Postman), so that switching my Claude account does not sign me out of
    my tools.
12. As a user, I want a switch to preserve everything else in my Claude config
    (projects, feature flags, my telemetry id), so that only the account identity
    changes.
13. As a user, I want a switch to be picked up by an already-running Claude Code
    session, so that I do not have to restart to use the new account.
14. As a user, I want the account I'm switching away from to be re-saved with its
    freshest credential, so that its slot does not silently die when I come back
    to it.
15. As a user, I want that re-capture to refuse to overwrite a slot with a
    credential that isn't that account's, so that a saved account is never
    poisoned by another account's token.
16. As a user, I want a switch that hits a failure partway through to roll back
    completely, so that I am never left with a broken or half-switched login.
17. As a user, I want a switch to never collide with Claude Code refreshing its
    own token, so that my switch does not get silently reverted.
18. As a user, I want re-running `ccswitch add` on an already-saved account to
    update it in place, so that I can refresh an expired slot by logging in and
    adding again, without creating a duplicate.
19. As a user, I want to save into a specific slot number with a flag, so that I
    can control the numbering when I want to.
20. As a user, I want a new account to take the lowest free slot number by
    default, so that I don't have to manage numbering myself.
21. As a user, I want to set or replace a slot's alias after the fact, so that I
    can rename without re-adding.
22. As a user, I want to remove a slot, so that I can drop accounts I no longer use.
23. As a user, I want removing the currently-active slot to be refused unless I
    force it, so that I don't accidentally leave myself logged in with no way to
    save that account back.
24. As a user, I want freed slot numbers to be reused rather than renumbering the
    others, so that my slot numbers stay stable.
25. As a user, I want secrets kept in the macOS Keychain and only non-secret
    metadata in a plaintext index, so that my tokens are not sitting in a readable
    file.
26. As a user on a machine where `~/.claude/.credentials.json` does not exist, I
    want ccswitch to not create it, so that no plaintext token is written that
    wasn't there before.
27. As a user who also logs into these accounts on another device, I want
    switching on this machine to remain safe, so that I don't corrupt or invalidate
    my logins elsewhere.
28. As a user on a headless or SSH session, I want a locked Keychain to fail fast
    with a clear message, so that a switch does not hang forever on an unlock prompt.
29. As a user, I want `ccswitch` to run with no install step and no runtime, so
    that I can just symlink one script onto my PATH.
30. As a user, I want ccswitch's Keychain access to not trigger a "wants to use
    your keychain" prompt after I upgrade my tools, so that switching stays
    frictionless over time.
31. As a user, I want clear guidance to seed my accounts (log in, then add) and a
    clear answer to "do I need to restart", so that setup is obvious.
32. As a user, I want switching to a non-existent or mistyped target to error
    clearly, so that I know it did nothing.
33. As a user, I want switching to the already-active account to be a reported
    no-op, so that a redundant switch is harmless.

## Implementation Decisions

**Platform and shape.** macOS only, OAuth accounts only, manual switching only.
Delivered as one executable bash script the user symlinks onto PATH — no runtime,
no package, no installer, no update check. The `claude-swap` project stays vendored
in-tree as the reference implementation these decisions are ported from.

**Source of truth on macOS.** The active Claude Code credential lives in the macOS
Keychain (generic-password, service `Claude Code-credentials`, account
`$(whoami)`), whose value is JSON containing `claudeAiOauth` (the account tokens)
and `mcpOAuth` (per-machine MCP server logins). Account identity metadata
(`oauthAccount`: email, org, uuids) lives separately in the global Claude config
file in `$HOME`. A third store, the per-machine credentials file under the Claude
config dir, is a hot-reload shadow that may not exist and is treated as optional.

**Keychain wrapper.** All Keychain access goes through the pinned absolute path
`/usr/bin/security` (never a `security` found on PATH, never a language binding),
so the item's ACL binds to a stable system binary and no re-authorization prompt
appears across tool upgrades. Three shell functions form the seam: read, write,
delete. Read distinguishes the "item not found" return code (44) as a clean miss
from real errors, and retries once on a real error. Write hex-encodes the value
and passes it via `security -i` on stdin to keep the secret out of the process
argument list, with a fallback to the argument form when the assembled stdin line
would exceed the ~4032-byte limit at which `security -i` silently truncates.
Delete treats both success and not-found as success. Every `security` invocation
is bounded by a ~5-second timeout implemented with a backgrounded call and a kill,
because macOS ships no `timeout(1)`.

**Storage.** Each saved account is one Keychain generic-password item under
service `ccswitch`, account `slot-<N>`, whose value is JSON carrying only
`claudeAiOauth`. A plaintext index at `~/.ccswitch/accounts.json` (directory mode
0700, file mode 0600) holds no secrets: a versioned list of records, each with
slot number, email, optional alias, organization uuid, organization name, and the
account's `oauthAccount` object stored verbatim. Account identity is the composite
`(email, organizationUuid)`.

**Commands.** `add [--slot N] [--alias NAME]`, `list`, `status`,
`switch <N|email|alias>`, `alias <N|email> <name>`, `remove <N|email> [--force]`,
`help`. Selector resolution: a bare integer is a slot number; otherwise match an
alias, otherwise an email; an email matching multiple slots errors and lists the
candidates. The active account is derived at read time by matching the live
`oauthAccount` identity against the index — there is no persisted active pointer
to drift.

**add.** Read the live `claudeAiOauth` from the Keychain (error, with a "log in
first" hint, if absent) and the live `oauthAccount` from the global config (error
if absent). If `(email, org)` already exists, overwrite that slot; else use the
requested slot or the lowest free number. Write the slot's Keychain item, then
update the index.

**switch.** Determine the target (a switch to the already-active account is a
reported no-op). Before mutating, perform a **local, network-free re-capture of
the outgoing account**: find the slot whose stored `(email, org)` equals the live
`oauthAccount`; if found, re-write the live `claudeAiOauth` into that slot so a
rotated refresh token is captured and the slot cannot go stale; if not found, skip
re-capture so a foreign login can never poison a slot. This is the reference's
outgoing-credential protection with its profile-endpoint network oracle replaced
by the locally-available `oauthAccount` identity — chosen deliberately for
simplicity and confirmed safe under multi-device login, since each device holds an
independent refresh-token lineage while the `(email, org)` identity is identical
everywhere.

Then, holding **both of Claude Code's own advisory locks** (the refresh lock and
the config lock, which are `mkdir`-based advisory directory locks; acquire by
`mkdir`, break a lock whose directory mtime is older than ~10 seconds, retry for
~9 seconds total, and release via a trap on EXIT/INT/TERM), and after snapshotting
the stores to be touched, write in order: (1) the active Keychain item, replacing
only `claudeAiOauth` and preserving `mcpOAuth`; (2) the global config, replacing
only `oauthAccount` and preserving every other key, via atomic temp-file-and-rename
preserving mode; (3) the shadow credentials file **only if it already exists**,
rewritten via temp-file, chmod 0600, and rename to bump its mtime for hot-reload —
never created when absent. Any failure restores all touched stores from the
snapshot and exits non-zero. No network calls are made while holding the locks.
On success, print the new active account and note the ~30-second hot-reload / or
restart behavior.

**JSON manipulation** is done with `jq` (built into macOS 15+), using targeted
key assignment so only the intended key changes and all sibling keys survive
verbatim.

**remove** deletes the slot's Keychain item and its index entry, refuses the
active slot unless forced, and never renumbers surviving slots.

**Seeding.** Initial seeding is done by logging into each account and running
`add`; there is no import-from-dump path. The `docs/credentials-*.json` files are
**expired** sample dumps kept only to document the credential shape — they hold no
live secrets, so they need no gitignoring or deletion.

## Testing Decisions

**What a good test asserts here:** external, observable behavior — what ends up in
the (stubbed) Keychain and in the index and config files after a command — not the
internal shape of helper functions. State is redirected into a temporary `$HOME`
so no test touches the developer's real config.

**Two seams, matching the reference project's split:**

1. *Primary seam — the three Keychain shell functions (read/write/delete).* The
   fast suite stubs these with an in-memory/file-backed fake, so it never touches
   the real login Keychain and runs anywhere. This is the single seam through
   which almost all behavior is exercised. Prior art:
   `claude-swap/tests/conftest.py` autouse `block_real_keychain` fixture and its
   `_isolate_real_home` fixture.
2. *Contract seam — the real `/usr/bin/security` wrapper against a throwaway
   keychain.* A small, macOS-only suite creates a temporary keychain and asserts
   that the actual `security` command shapes (read, the not-found return code, the
   stdin-vs-argument write paths and the truncation-threshold fallback, hex
   round-trip, delete) behave as assumed. Prior art:
   `claude-swap/tests/test_macos_keychain.py` (mocked argv/stdin/return-code
   shaping) and `claude-swap/tests/test_macos_keychain_contract.py` (real
   throwaway-keychain fixture).

**Behaviors under test (primary seam):** add-then-list reports the right slot,
email, org, and alias; add on an existing `(email, org)` updates in place with no
duplicate; the same email under two orgs yields two slots and an ambiguous-email
switch errors; selector resolution reaches the right slot by number, alias, and
email; switch preserves `mcpOAuth` and replaces only `claudeAiOauth`; switch
preserves every config key except `oauthAccount` (specifically the telemetry id
survives); switch re-captures the outgoing slot when the live identity matches and
skips re-capture when it does not; switch rewrites the shadow file (mtime bump)
when present and does not create it when absent; an injected failure at the final
write rolls back all touched stores; lock acquisition fails cleanly against a fresh
held lock and breaks a stale one; the write path falls back to the argument form
above the truncation threshold.

Tooling note: the target machine has no `bats`, so tests are plain bash with
assertions; the tool suite is `test.sh` at the repo root.

## Out of Scope

Usage and quota tracking; automatic or threshold-based switching; a TUI or menu-bar
app; session mode / running two accounts in parallel; per-directory account
mapping; export/import and importing accounts from raw credential dumps;
API-key-based accounts; Linux and Windows support; any installer, packaging, or
self-update mechanism.

## Further Notes

- The previous design (`docs/superpowers/specs/2026-07-19-ccswitch-design.md`) is
  superseded: it centered the per-machine credentials file, which is the Linux
  credential store; this spec is macOS-first with the Keychain as source of truth.
- Confirmed on the target machine (2026-07-22): the `Claude Code-credentials`
  Keychain item is present; no `Claude Code` API-key item (accounts are OAuth); the
  shadow credentials file is absent; `jq`, `python3`, `security`, and `plutil` are
  present; `bats` and `timeout(1)` are not.
- No project issue tracker is configured, so this spec is filed as a repository
  document rather than a tracked issue with a `ready-for-agent` label.
