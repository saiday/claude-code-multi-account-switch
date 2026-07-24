#!/bin/bash
#
# Contract suite for ccswitch's real Keychain wrapper.
#
# Unlike test.sh (which stubs the seam), this drives the actual /usr/bin/security
# wrapper (kc_read / kc_write / kc_delete) against a THROWAWAY keychain, to
# validate that the real command shapes behave as the code assumes: read,
# rc-44 not-found, the stdin-vs-argv write paths and the ~4032-byte truncation
# fallback, hex round-trip, and delete.
#
# It temporarily swaps the default keychain and the user search list to the
# throwaway one and restores both via an EXIT trap. Because that mutates
# keychain configuration, it is OPT-IN: it does nothing unless CCSWITCH_CONTRACT=1,
# so a casual `bash test_contract.sh` can never disturb the real login keychain.

set -u

if [ "$(uname)" != "Darwin" ]; then
  printf 'test_contract.sh: skipped (not macOS)\n'
  exit 0
fi
if [ "${CCSWITCH_CONTRACT:-}" != "1" ]; then
  printf 'test_contract.sh: skipped. Set CCSWITCH_CONTRACT=1 to run against a throwaway keychain.\n'
  exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ccswitch disable=SC1091
source "$SCRIPT_DIR/ccswitch"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$1" = "$2" ]; then ok; else fail "$3: expected [$1] got [$2]"; fi; }
assert_rc() { if [ "$1" -eq "$2" ]; then ok; else fail "$3: expected rc $1 got $2"; fi; }

# --- throwaway keychain fixture ---------------------------------------------

TEST_KEYCHAIN=""
ORIG_DEFAULT=""
ORIG_LIST=""

restore_keychain() {
  # Restore the search list BEFORE the default: macOS won't report a default
  # keychain that isn't in the search list.
  if [ -n "$ORIG_LIST" ]; then
    # shellcheck disable=SC2086
    "$CC_SECURITY" list-keychains -d user -s $ORIG_LIST >/dev/null 2>&1
  fi
  if [ -n "$ORIG_DEFAULT" ]; then
    "$CC_SECURITY" default-keychain -s "$ORIG_DEFAULT" >/dev/null 2>&1
  fi
  if [ -n "$TEST_KEYCHAIN" ]; then
    "$CC_SECURITY" delete-keychain "$TEST_KEYCHAIN" >/dev/null 2>&1
    rm -rf "$(dirname "$TEST_KEYCHAIN")"
  fi
}
trap restore_keychain EXIT INT TERM

setup_keychain() {
  local dir
  dir=$(mktemp -d)
  TEST_KEYCHAIN="$dir/ccswitch-test.keychain"

  ORIG_DEFAULT=$("$CC_SECURITY" default-keychain 2>/dev/null | sed -e 's/^ *"//' -e 's/" *$//')
  ORIG_LIST=$("$CC_SECURITY" list-keychains -d user 2>/dev/null | sed -e 's/^ *"//' -e 's/" *$//' | tr '\n' ' ')

  "$CC_SECURITY" create-keychain -p "" "$TEST_KEYCHAIN"
  "$CC_SECURITY" default-keychain -s "$TEST_KEYCHAIN"
  "$CC_SECURITY" list-keychains -d user -s "$TEST_KEYCHAIN"
  # Remove the auto-lock timeout, then unlock, so no invisible unlock dialog can
  # wedge the run on a headless host.
  "$CC_SECURITY" set-keychain-settings "$TEST_KEYCHAIN"
  "$CC_SECURITY" unlock-keychain -p "" "$TEST_KEYCHAIN"
}

# --- tests ------------------------------------------------------------------

SVC="ccswitch-contract-test"

test_read_externally_seeded_item() {
  # kc_read must find an item created the way Claude Code creates its own (-w).
  "$CC_SECURITY" add-generic-password -U -a "acct-seed" -s "$SVC" -w "seeded-value" "$TEST_KEYCHAIN"
  local v rc
  v=$(kc_read "$SVC" "acct-seed"); rc=$?
  assert_rc 0 "$rc" "read seeded item returns 0"
  assert_eq "seeded-value" "$v" "read returns the seeded value"
}

test_read_not_found_is_rc_44() {
  local rc
  kc_read "$SVC" "acct-does-not-exist" >/dev/null; rc=$?
  assert_rc 44 "$rc" "missing item read returns rc 44"
}

test_write_stdin_path_roundtrip() {
  local value='{"claudeAiOauth":{"accessToken":"stdin-token"}}'
  kc_write "$SVC" "acct-stdin" "$value"
  assert_rc 0 "$?" "small write succeeds"
  assert_eq "stdin" "$CCSWITCH_LAST_WRITE_PATH" "small payload uses the stdin path"
  assert_eq "$value" "$(kc_read "$SVC" "acct-stdin")" "stdin write round-trips"
}

test_write_argv_fallback_roundtrip() {
  # A value large enough that the hex-encoded stdin command line exceeds the
  # ~4032-byte truncation threshold, forcing the argv fallback.
  local big value
  big=$(head -c 2100 </dev/zero | tr '\0' 'x')
  value="{\"claudeAiOauth\":{\"accessToken\":\"$big\"}}"
  kc_write "$SVC" "acct-argv" "$value"
  assert_rc 0 "$?" "large write succeeds"
  assert_eq "argv" "$CCSWITCH_LAST_WRITE_PATH" "oversized payload falls back to the argv path"
  assert_eq "$value" "$(kc_read "$SVC" "acct-argv")" "argv write round-trips"
}

test_hex_roundtrip_special_chars() {
  # Values with the characters _kc_quote must escape (space, quote, backslash).
  local value='{"a":"x \"q\" \\ end","b":"a b c"}'
  kc_write "$SVC" "acct-special" "$value"
  assert_rc 0 "$?" "special-char write succeeds"
  assert_eq "$value" "$(kc_read "$SVC" "acct-special")" "special characters survive the hex round-trip"
}

test_delete() {
  kc_write "$SVC" "acct-del" '{"x":1}'
  local rc
  kc_delete "$SVC" "acct-del"; rc=$?
  assert_rc 0 "$rc" "delete of an existing item returns 0"
  kc_read "$SVC" "acct-del" >/dev/null; rc=$?
  assert_rc 44 "$rc" "read after delete returns rc 44"
  kc_delete "$SVC" "acct-del"; rc=$?
  assert_rc 0 "$rc" "delete of an absent item is a success (rc-44 tolerated)"
}

# --- run all ----------------------------------------------------------------

setup_keychain
for t in \
  test_read_externally_seeded_item \
  test_read_not_found_is_rc_44 \
  test_write_stdin_path_roundtrip \
  test_write_argv_fallback_roundtrip \
  test_hex_roundtrip_special_chars \
  test_delete; do
  "$t"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
