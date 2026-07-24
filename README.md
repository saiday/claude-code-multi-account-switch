# ccswitch

Switch between multiple Claude Code OAuth accounts on macOS, with no browser re-auth.

The macOS Keychain (`Claude Code-credentials`) is the source of truth. ccswitch saves a snapshot of each account and swaps the live credential in place, so switching is instant. It is a single bash script: no install step, no runtime.

**Requirements:** macOS (system `/bin/bash`), `jq`, and Claude Code logged in at least once.

## Install

`ccswitch` is the whole tool. Symlink it onto your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -s "$PWD/ccswitch" ~/.local/bin/ccswitch
```

If `~/.local/bin` is not on your `PATH`, add it and reload your shell:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Verify with `ccswitch help`.

## Setup

ccswitch does not create logins. It snapshots whatever account is **currently live** in Claude Code, so enrolling accounts is a one-time loop: log into each one normally, then `ccswitch add`.

```sh
# 1. Log into the first account in Claude Code (/login), then:
ccswitch add --alias work        # Saved you@company.com (Company Org) to slot 1.

# 2. In Claude Code, /logout and /login as the next account, then:
ccswitch add --alias personal    # Saved you@gmail.com (Personal) to slot 2.

# 3. Repeat for each account. Each add takes the next free slot (--slot N to pick).
```

`--alias` is optional; without it an account is still reachable by slot number or email. Confirm what you saved (`*` marks the live account):

```sh
ccswitch list
```

```
SLOT ACTIVE EMAIL                          ORG          ALIAS
1           you@company.com                Company Org  work
2    *      you@gmail.com                  Personal     personal
```

## Switch

Refer to an account by alias, slot number, or email:

```sh
ccswitch switch work
ccswitch switch 2
ccswitch switch you@gmail.com
```

Restart Claude Code (or start a new session) to pick up the switched login.

## Other commands

```sh
ccswitch status              # show the currently active account
ccswitch alias 2 personal    # set or rename a saved account's alias
ccswitch remove work         # drop a saved account
ccswitch remove work --force # required to remove the active account
ccswitch help                # full help
```

## Notes

- **Re-adding refreshes in place.** Running `ccswitch add` for an account you already saved updates its stored credential (e.g. after a token refresh) and keeps its slot and alias.
- **Ambiguous emails.** If one email belongs to two orgs, refer to it by slot number or alias.

## License

[MIT](LICENSE)
