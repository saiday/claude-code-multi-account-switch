#!/bin/bash
#
# Fast test suite for ccswitch.
#
# Runs anywhere: the three Keychain seam functions (kc_read / kc_write /
# kc_delete) are redefined below with a file-backed fake, and $HOME is
# redirected to a throwaway dir, so nothing here touches the real login
# Keychain or the developer's real Claude config. `main` is always invoked
# inside a $( ) subshell so that `die`'s `exit` ends the subshell, not this
# harness.
#
# The real Keychain wrapper (the actual `security` command shapes) is covered
# by the separate macOS-only test_contract.sh.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ccswitch disable=SC1091
source "$SCRIPT_DIR/ccswitch"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

assert_eq() { # expected actual msg
  if [ "$1" = "$2" ]; then ok; else fail "$3: expected [$1] got [$2]"; fi
}
assert_contains() { # haystack needle msg
  case "$1" in *"$2"*) ok ;; *) fail "$3: output does not contain [$2]" ;; esac
}
assert_not_contains() { # haystack needle msg
  case "$1" in *"$2"*) fail "$3: output unexpectedly contains [$2]" ;; *) ok ;; esac
}
assert_rc() { # expected actual msg
  if [ "$1" -eq "$2" ]; then ok; else fail "$3: expected rc $1 got $2"; fi
}

# --- file-backed fake for the Keychain seam ---------------------------------
_fake_key() { printf '%s' "$1::$2" | tr -c 'A-Za-z0-9' '_'; }
kc_read() {
  local f="$FAKE_KC/$(_fake_key "$1" "$2")"
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  return 44
}
kc_write() {
  local f="$FAKE_KC/$(_fake_key "$1" "$2")"
  printf '%s' "$3" >"$f"
}
kc_delete() {
  rm -f "$FAKE_KC/$(_fake_key "$1" "$2")"
}

# --- fixtures ---------------------------------------------------------------
fresh_env() {
  TEST_HOME=$(mktemp -d)
  FAKE_KC=$(mktemp -d)
  export HOME="$TEST_HOME"
  unset CLAUDE_CONFIG_DIR
}
seed_active() { kc_write "$CC_CRED_SERVICE" "$(active_account_name)" "$1"; }
seed_config() { printf '%s' "$1" | jq '{oauthAccount: .}' >"$HOME/.claude.json"; }
slot_value() { kc_read "$CCSWITCH_SERVICE" "slot-$1"; }
index_json() { cat "$HOME/.ccswitch/accounts.json"; }
run() { OUT=$(main "$@" 2>&1); RC=$?; }

CRED_A='{"claudeAiOauth":{"accessToken":"at-A","refreshToken":"rt-A","expiresAt":1},"mcpOAuth":{"slack":{"accessToken":"mcp-A"}}}'
OAUTH_ORG='{"emailAddress":"stan@work.com","accountUuid":"uuid-B","organizationUuid":"org-1","organizationName":"Acme"}'
OAUTH_PERSONAL='{"emailAddress":"stan@personal.com","accountUuid":"uuid-A"}'

# Distinct live credentials (each carries an mcpOAuth blob) so a switch's
# preserve-mcpOAuth and re-capture behavior is observable by token value.
CRED_WORK='{"claudeAiOauth":{"accessToken":"at-work","refreshToken":"rt-work"},"mcpOAuth":{"slack":{"accessToken":"mcp-A"}}}'
CRED_PERS='{"claudeAiOauth":{"accessToken":"at-pers","refreshToken":"rt-pers"},"mcpOAuth":{"figma":{"accessToken":"mcp-F"}}}'
OAUTH_FOREIGN='{"emailAddress":"ghost@nowhere.dev","accountUuid":"uuid-Z","organizationUuid":"org-Z","organizationName":"Ghost"}'

# --- tests ------------------------------------------------------------------

test_add_then_list() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"
  run add
  assert_rc 0 "$RC" "add succeeds on a logged-in account"
  local sv; sv=$(slot_value 1)
  assert_contains "$sv" "at-A" "slot keychain item carries claudeAiOauth"
  assert_not_contains "$sv" "mcp-A" "slot keychain item does not carry mcpOAuth"
  local idx; idx=$(index_json)
  assert_contains "$idx" "stan@work.com" "index records email"
  assert_contains "$idx" "org-1" "index records org uuid"
  run list
  assert_contains "$OUT" "stan@work.com" "list shows email"
  assert_contains "$OUT" "Acme" "list shows org name"
  assert_eq 1 "$(index_json | jq -r '.accounts[0].slot')" "saved to slot 1"
}

test_add_updates_in_place() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"
  run add
  seed_active '{"claudeAiOauth":{"accessToken":"at-A2"},"mcpOAuth":{}}'
  run add
  assert_rc 0 "$RC" "re-add succeeds"
  assert_eq 1 "$(index_json | jq '.accounts | length')" "no duplicate slot on re-add"
  assert_contains "$(slot_value 1)" "at-A2" "slot refreshed with newest credential"
}

test_add_explicit_slot() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"
  run add --slot 5
  assert_rc 0 "$RC" "--slot add succeeds"
  assert_eq 5 "$(index_json | jq '.accounts[0].slot')" "--slot N honored"
  assert_contains "$(slot_value 5)" "at-A" "credential stored under requested slot"
}

test_add_lowest_free_slot() {
  fresh_env
  seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add --slot 1
  seed_active "$CRED_A"; seed_config '{"emailAddress":"c@x.com","accountUuid":"u3","organizationUuid":"o3","organizationName":"O3"}'; run add --slot 3
  seed_active "$CRED_A"; seed_config '{"emailAddress":"d@x.com","accountUuid":"u2","organizationUuid":"o2","organizationName":"O2"}'; run add
  assert_eq 2 "$(index_json | jq -r '.accounts[] | select(.email=="d@x.com") | .slot')" "new account takes lowest free slot (2)"
}

test_same_email_two_orgs() {
  fresh_env
  seed_active "$CRED_A"; seed_config '{"emailAddress":"same@x.com","accountUuid":"u1","organizationUuid":"orgA","organizationName":"A"}'; run add
  seed_active "$CRED_A"; seed_config '{"emailAddress":"same@x.com","accountUuid":"u1","organizationUuid":"orgB","organizationName":"B"}'; run add
  assert_eq 2 "$(index_json | jq '.accounts | length')" "same email under two orgs yields two slots"
}

test_add_errors_without_credential() {
  fresh_env; seed_config "$OAUTH_ORG"
  run add
  assert_rc 1 "$RC" "add errors when no live credential"
  assert_contains "$OUT" "Log in first" "error hints to log in first"
}

test_add_errors_without_oauth_account() {
  fresh_env; seed_active "$CRED_A"
  run add
  assert_rc 1 "$RC" "add errors when no oauthAccount in config"
}

test_active_marker_and_status() {
  fresh_env
  seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add
  seed_active "$CRED_A"; seed_config "$OAUTH_PERSONAL"; run add
  seed_config "$OAUTH_ORG" # live account is now the org one
  run list
  local work_line pers_line
  work_line=$(printf '%s\n' "$OUT" | grep 'stan@work.com')
  pers_line=$(printf '%s\n' "$OUT" | grep 'stan@personal.com')
  assert_contains "$work_line" "*" "active marker on the live slot"
  assert_not_contains "$pers_line" "*" "no marker on the non-live slot"
  run status
  assert_rc 0 "$RC" "status succeeds"
  assert_contains "$OUT" "stan@work.com" "status prints the live account"
  assert_contains "$OUT" "Active" "status labels the active account"
}

test_status_not_logged_in() {
  fresh_env
  run status
  assert_contains "$OUT" "Not logged in" "status reports no active login"
}

test_index_permissions_and_no_secrets() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add
  assert_eq 700 "$(stat -f '%Lp' "$HOME/.ccswitch")" "index dir is mode 0700"
  assert_eq 600 "$(stat -f '%Lp' "$HOME/.ccswitch/accounts.json")" "index file is mode 0600"
  local idx; idx=$(index_json)
  assert_not_contains "$idx" "at-A" "index holds no access token"
  assert_not_contains "$idx" "rt-A" "index holds no refresh token"
}

test_help() {
  fresh_env
  run help
  assert_rc 0 "$RC" "help succeeds"
  assert_contains "$OUT" "add" "help documents add"
  assert_contains "$OUT" "list" "help documents list"
  assert_contains "$OUT" "status" "help documents status"
  assert_contains "$OUT" "alias" "help documents alias"
  assert_contains "$OUT" "remove" "help documents remove"
  run # no args
  assert_contains "$OUT" "add" "bare invocation prints usage"
}

# --- selector resolution + alias (issue #2) ---------------------------------

resolve() { R_OUT=$(resolve_selector "$1" "$2" 2>&1); R_RC=$?; }

seed_two_orgs_same_email() {
  # Two saved slots sharing one email under different orgs.
  seed_active "$CRED_A"; seed_config '{"emailAddress":"same@x.com","accountUuid":"u1","organizationUuid":"orgA","organizationName":"A"}'; run add
  seed_active "$CRED_A"; seed_config '{"emailAddress":"same@x.com","accountUuid":"u1","organizationUuid":"orgB","organizationName":"B"}'; run add
}

test_resolve_by_slot() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add --slot 3
  resolve "$(read_index)" 3
  assert_rc 0 "$R_RC" "bare integer resolves"
  assert_eq 3 "$R_OUT" "bare integer resolves to that slot"
  resolve "$(read_index)" 9
  assert_rc 1 "$R_RC" "unknown slot number errors"
}

test_resolve_by_alias() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add --slot 2 --alias work
  resolve "$(read_index)" work
  assert_rc 0 "$R_RC" "alias resolves"
  assert_eq 2 "$R_OUT" "alias resolves to the slot carrying it"
  resolve "$(read_index)" WORK
  assert_rc 0 "$R_RC" "alias match is case-insensitive"
  assert_eq 2 "$R_OUT" "mixed-case alias resolves to the same slot"
}

test_resolve_by_email() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add --slot 4
  resolve "$(read_index)" stan@work.com
  assert_rc 0 "$R_RC" "email resolves"
  assert_eq 4 "$R_OUT" "email resolves to the matching slot"
}

test_resolve_ambiguous_email() {
  fresh_env; seed_two_orgs_same_email
  resolve "$(read_index)" same@x.com
  assert_rc 1 "$R_RC" "ambiguous email errors"
  assert_contains "$R_OUT" "more than one" "ambiguous error explains the clash"
  assert_contains "$R_OUT" "slot 1" "ambiguous error lists candidate slot 1"
  assert_contains "$R_OUT" "slot 2" "ambiguous error lists candidate slot 2"
}

test_resolve_unknown() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add
  resolve "$(read_index)" nope@nowhere.dev
  assert_rc 1 "$R_RC" "unknown selector errors"
  assert_contains "$R_OUT" "unknown" "unknown selector explained clearly"
}

test_add_alias_flag() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"
  run add --alias work
  assert_rc 0 "$RC" "add --alias succeeds"
  assert_eq "work" "$(index_json | jq -r '.accounts[0].alias')" "add --alias stores the alias"
  run list
  assert_contains "$OUT" "work" "list shows the alias"
}

test_add_alias_preserved_on_readd() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add --alias work
  seed_active '{"claudeAiOauth":{"accessToken":"at-A2"},"mcpOAuth":{}}'
  run add
  assert_eq "work" "$(index_json | jq -r '.accounts[0].alias')" "re-add without --alias keeps the existing alias"
}

test_add_alias_rejects_numeric() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"
  run add --alias 7
  assert_rc 1 "$RC" "numeric alias is refused"
  assert_contains "$OUT" "numeric" "error explains alias cannot be a number"
  assert_eq "" "$(slot_value 1)" "nothing written to the keychain when the alias is invalid"
}

test_alias_command_sets() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add
  run alias 1 work
  assert_rc 0 "$RC" "alias command succeeds"
  assert_eq "work" "$(index_json | jq -r '.accounts[0].alias')" "alias set on the slot after the fact"
  run list
  assert_contains "$OUT" "work" "list shows the alias set after the fact"
}

test_alias_command_replaces() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add --alias work
  run alias 1 job
  assert_rc 0 "$RC" "alias replace succeeds"
  assert_eq "job" "$(index_json | jq -r '.accounts[0].alias')" "alias replaced in place"
}

test_alias_command_by_email() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add
  run alias stan@work.com boss
  assert_rc 0 "$RC" "alias by email succeeds"
  assert_eq "boss" "$(index_json | jq -r '.accounts[0].alias')" "alias set when selecting by email"
}

test_alias_rejects_duplicate() {
  fresh_env
  seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add --alias work
  seed_active "$CRED_A"; seed_config "$OAUTH_PERSONAL"; run add
  run alias 2 work
  assert_rc 1 "$RC" "duplicate alias is refused"
  assert_contains "$OUT" "already used" "error names the conflicting slot"
  assert_eq "NONE" "$(index_json | jq -r '.accounts[] | select(.slot==2) | (.alias // "NONE")')" "slot 2 alias unchanged after the clash"
}

test_alias_unknown_selector_changes_nothing() {
  fresh_env; seed_active "$CRED_A"; seed_config "$OAUTH_ORG"; run add
  run alias 99 work
  assert_rc 1 "$RC" "alias with an unknown slot errors"
  assert_eq "NONE" "$(index_json | jq -r '.accounts[0] | (.alias // "NONE")')" "index unchanged after a failed alias"
}

# --- switch (issue #3) -------------------------------------------------------

live_cred() { kc_read "$CC_CRED_SERVICE" "$(active_account_name)"; }

seed_full_config() { printf '%s' "$1" >"$HOME/.claude.json"; }

# Save work (slot 1) and personal (slot 2), then leave work the live account.
seed_switch_slots() {
  seed_active "$CRED_WORK"; seed_config "$OAUTH_ORG"; run add
  seed_active "$CRED_PERS"; seed_config "$OAUTH_PERSONAL"; run add
  seed_active "$CRED_WORK"; seed_config "$OAUTH_ORG"
}

test_switch_makes_active() {
  fresh_env; seed_switch_slots
  run switch 2
  assert_rc 0 "$RC" "switch to a saved slot succeeds"
  assert_contains "$(live_cred)" "at-pers" "live keychain now carries the target's token"
  assert_contains "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")" "stan@personal.com" "config oauthAccount now the target"
  run status
  assert_contains "$OUT" "stan@personal.com" "status reflects the switched account"
  run list
  local pers_line work_line
  pers_line=$(printf '%s\n' "$OUT" | grep 'stan@personal.com')
  work_line=$(printf '%s\n' "$OUT" | grep 'stan@work.com')
  assert_contains "$pers_line" "*" "list marks the switched-to slot active"
  assert_not_contains "$work_line" "*" "previously-active slot no longer marked"
}

test_switch_preserves_mcpOAuth() {
  fresh_env; seed_switch_slots
  run switch 2
  local lc; lc=$(live_cred)
  assert_contains "$lc" "mcp-A" "mcpOAuth from the outgoing live item survives the switch"
  assert_eq "at-pers" "$(printf '%s' "$lc" | jq -r '.claudeAiOauth.accessToken')" "only claudeAiOauth changed in the keychain"
}

test_switch_preserves_config_keys() {
  fresh_env
  seed_active "$CRED_WORK"; seed_config "$OAUTH_ORG"; run add
  seed_active "$CRED_PERS"; seed_config "$OAUTH_PERSONAL"; run add
  # A rich live config with a telemetry id and unrelated keys.
  seed_full_config '{"oauthAccount":'"$OAUTH_ORG"',"userID":"telemetry-xyz","numStartups":42,"projects":{"/x":{}}}'
  run switch 2
  assert_rc 0 "$RC" "switch succeeds with a rich config"
  assert_eq "telemetry-xyz" "$(jq -r '.userID' "$HOME/.claude.json")" "telemetry id survives the switch"
  assert_eq "42" "$(jq -r '.numStartups' "$HOME/.claude.json")" "unrelated config keys survive the switch"
  assert_eq "stan@personal.com" "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")" "only oauthAccount changed"
}

test_switch_recaptures_outgoing() {
  fresh_env; seed_switch_slots
  # The live work credential rotated since it was saved.
  seed_active '{"claudeAiOauth":{"accessToken":"at-work2","refreshToken":"rt-work2"},"mcpOAuth":{"slack":{"accessToken":"mcp-A"}}}'
  run switch 2
  assert_rc 0 "$RC" "switch succeeds"
  assert_contains "$(slot_value 1)" "at-work2" "outgoing slot re-captured with the freshest live token"
}

test_switch_recapture_skipped_when_no_match() {
  fresh_env; seed_switch_slots
  # A foreign login is live (matches no saved slot): re-capture must be skipped.
  seed_active '{"claudeAiOauth":{"accessToken":"at-foreign","refreshToken":"rt-foreign"},"mcpOAuth":{}}'
  seed_config "$OAUTH_FOREIGN"
  run switch 1
  assert_rc 0 "$RC" "switch away from a foreign login succeeds"
  assert_not_contains "$(slot_value 1)" "at-foreign" "poison guard: slot 1 not overwritten with the foreign token"
  assert_not_contains "$(slot_value 2)" "at-foreign" "poison guard: slot 2 not overwritten with the foreign token"
}

test_switch_shadow_present_rewritten() {
  fresh_env; seed_switch_slots
  mkdir -p "$HOME/.claude"
  printf '%s' "$CRED_WORK" >"$HOME/.claude/.credentials.json"
  touch -t 202001010000 "$HOME/.claude/.credentials.json"
  local before; before=$(stat -f '%m' "$HOME/.claude/.credentials.json")
  run switch 2
  assert_rc 0 "$RC" "switch succeeds with a shadow file present"
  assert_contains "$(cat "$HOME/.claude/.credentials.json")" "at-pers" "shadow file rewritten with the new credential"
  local after; after=$(stat -f '%m' "$HOME/.claude/.credentials.json")
  if [ "$after" -gt "$before" ]; then ok; else fail "shadow file mtime should be bumped"; fi
}

test_switch_shadow_absent_not_created() {
  fresh_env; seed_switch_slots
  run switch 2
  assert_rc 0 "$RC" "switch succeeds with no shadow file"
  if [ -e "$HOME/.claude/.credentials.json" ]; then
    fail "shadow file must not be created when absent"
  else
    ok
  fi
}

test_switch_rollback_on_final_write_failure() {
  fresh_env; seed_switch_slots
  mkdir -p "$HOME/.claude"
  printf '%s' "$CRED_WORK" >"$HOME/.claude/.credentials.json"
  # Make the shadow file's directory unwritable so the final (shadow) write
  # fails; the whole switch must then roll every touched store back.
  chmod 0500 "$HOME/.claude"
  run switch 2
  chmod 0700 "$HOME/.claude"
  assert_rc 1 "$RC" "a failed final write makes the switch exit non-zero"
  assert_contains "$(live_cred)" "at-work" "keychain rolled back to the pre-switch credential"
  assert_eq "stan@work.com" "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")" "config rolled back to the pre-switch account"
}

test_switch_already_active_noop() {
  fresh_env; seed_switch_slots
  run switch 1
  assert_rc 0 "$RC" "switching to the already-active account is not an error"
  assert_contains "$OUT" "Already active" "no-op is reported"
  assert_contains "$(live_cred)" "at-work" "live credential unchanged on a no-op switch"
}

test_switch_unknown_target_errors() {
  fresh_env; seed_switch_slots
  run switch nope@nowhere.dev
  assert_rc 1 "$RC" "a mistyped target errors"
  assert_contains "$(live_cred)" "at-work" "nothing changed after a failed switch"
  assert_eq "stan@work.com" "$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude.json")" "config unchanged after a failed switch"
}

# --- remove (issue #4) -------------------------------------------------------

test_remove_non_active() {
  fresh_env; seed_switch_slots # slot 1 work (live), slot 2 personal
  run remove 2
  assert_rc 0 "$RC" "remove a non-active slot succeeds"
  assert_eq "" "$(slot_value 2)" "removed slot's keychain item is gone"
  assert_eq 1 "$(index_json | jq '.accounts | length')" "removed slot's index entry is gone"
  assert_eq "" "$(index_json | jq -r '.accounts[] | select(.slot==2) | .slot')" "no slot-2 record remains"
  assert_contains "$(slot_value 1)" "at-work" "the untouched slot's credential survives"
}

test_remove_by_alias() {
  fresh_env
  seed_active "$CRED_WORK"; seed_config "$OAUTH_ORG"; run add --alias work
  seed_active "$CRED_PERS"; seed_config "$OAUTH_PERSONAL"; run add --alias pers
  seed_active "$CRED_WORK"; seed_config "$OAUTH_ORG" # work is live
  run remove pers
  assert_rc 0 "$RC" "remove by alias succeeds"
  assert_eq "" "$(slot_value 2)" "remove by alias deletes the slot the alias names"
  assert_eq 1 "$(index_json | jq '.accounts | length')" "only the aliased slot's entry is removed"
}

test_remove_active_refused_without_force() {
  fresh_env; seed_switch_slots # work (slot 1) is the live account
  run remove 1
  assert_rc 1 "$RC" "removing the active slot is refused without --force"
  assert_contains "$OUT" "force" "the refusal points the user at --force"
  assert_contains "$(slot_value 1)" "at-work" "the active slot's keychain item is untouched"
  assert_eq 2 "$(index_json | jq '.accounts | length')" "the index is unchanged after a refused remove"
}

test_remove_active_with_force() {
  fresh_env; seed_switch_slots # work (slot 1) is the live account
  run remove 1 --force
  assert_rc 0 "$RC" "removing the active slot succeeds with --force"
  assert_eq "" "$(slot_value 1)" "the active slot's keychain item is deleted with --force"
  assert_eq 1 "$(index_json | jq '.accounts | length')" "the active slot's index entry is removed with --force"
  assert_eq "" "$(index_json | jq -r '.accounts[] | select(.slot==1) | .slot')" "no slot-1 record remains"
}

test_remove_force_flag_before_selector() {
  fresh_env; seed_switch_slots
  run remove --force 1
  assert_rc 0 "$RC" "--force is accepted before the selector too"
  assert_eq "" "$(slot_value 1)" "the active slot is removed when --force leads"
}

test_remove_reuses_freed_slot() {
  fresh_env; seed_switch_slots # slot 1 work (live), slot 2 personal
  run remove 2 # frees slot number 2
  assert_eq 1 "$(index_json | jq -r '.accounts[] | select(.email=="stan@work.com") | .slot')" "the surviving slot keeps its number"
  # The next add takes the lowest free number, reusing the freed 2 rather than 3.
  seed_active "$CRED_A"; seed_config '{"emailAddress":"new@x.com","accountUuid":"un","organizationUuid":"on","organizationName":"On"}'
  run add
  assert_eq 2 "$(index_json | jq -r '.accounts[] | select(.email=="new@x.com") | .slot')" "the freed slot number is reused by the next add"
}

test_remove_unknown_target_changes_nothing() {
  fresh_env; seed_switch_slots
  run remove nope@nowhere.dev
  assert_rc 1 "$RC" "an unknown target errors"
  assert_contains "$OUT" "unknown" "the unknown target is explained clearly"
  assert_eq 2 "$(index_json | jq '.accounts | length')" "the index is unchanged after an unknown target"
  assert_contains "$(slot_value 1)" "at-work" "slot 1's keychain item is unchanged"
  assert_contains "$(slot_value 2)" "at-pers" "slot 2's keychain item is unchanged"
}

test_remove_requires_a_target() {
  fresh_env; seed_switch_slots
  run remove
  assert_rc 1 "$RC" "remove with no target errors"
  assert_eq 2 "$(index_json | jq '.accounts | length')" "the index is unchanged when no target is given"
}

# --- advisory locks (issue #3) ----------------------------------------------

test_lock_fresh_held_fails_cleanly() {
  fresh_env
  local d rc saved
  d=$(credentials_lock_dir)
  mkdir "$d" # a fresh lock, held by someone else
  saved="$CCSWITCH_LOCK_TIMEOUT"
  _CCSWITCH_HELD_LOCKS=""
  CCSWITCH_LOCK_TIMEOUT=0
  acquire_lock "$d"; rc=$?
  CCSWITCH_LOCK_TIMEOUT="$saved"
  assert_rc 1 "$rc" "acquiring a fresh-held lock fails cleanly"
  if [ -d "$d" ]; then ok; else fail "a fresh lock must not be broken"; fi
  rmdir "$d"
}

test_lock_stale_broken() {
  fresh_env
  local d rc
  d=$(credentials_lock_dir)
  mkdir "$d"
  touch -t 202001010000 "$d" # stale: mtime far older than the staleness window
  _CCSWITCH_HELD_LOCKS=""
  acquire_lock "$d"; rc=$?
  assert_rc 0 "$rc" "a stale lock is broken and re-acquired"
  if [ -d "$d" ]; then ok; else fail "lock dir should be held after acquisition"; fi
  release_locks
}

# --- run all ----------------------------------------------------------------
for t in \
  test_add_then_list \
  test_add_updates_in_place \
  test_add_explicit_slot \
  test_add_lowest_free_slot \
  test_same_email_two_orgs \
  test_add_errors_without_credential \
  test_add_errors_without_oauth_account \
  test_active_marker_and_status \
  test_status_not_logged_in \
  test_index_permissions_and_no_secrets \
  test_help \
  test_resolve_by_slot \
  test_resolve_by_alias \
  test_resolve_by_email \
  test_resolve_ambiguous_email \
  test_resolve_unknown \
  test_add_alias_flag \
  test_add_alias_preserved_on_readd \
  test_add_alias_rejects_numeric \
  test_alias_command_sets \
  test_alias_command_replaces \
  test_alias_command_by_email \
  test_alias_rejects_duplicate \
  test_alias_unknown_selector_changes_nothing \
  test_switch_makes_active \
  test_switch_preserves_mcpOAuth \
  test_switch_preserves_config_keys \
  test_switch_recaptures_outgoing \
  test_switch_recapture_skipped_when_no_match \
  test_switch_shadow_present_rewritten \
  test_switch_shadow_absent_not_created \
  test_switch_rollback_on_final_write_failure \
  test_switch_already_active_noop \
  test_switch_unknown_target_errors \
  test_remove_non_active \
  test_remove_by_alias \
  test_remove_active_refused_without_force \
  test_remove_active_with_force \
  test_remove_force_flag_before_selector \
  test_remove_reuses_freed_slot \
  test_remove_unknown_target_changes_nothing \
  test_remove_requires_a_target \
  test_lock_fresh_held_fails_cleanly \
  test_lock_stale_broken; do
  "$t"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
