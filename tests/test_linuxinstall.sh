#!/usr/bin/env bash
# tests/test_linuxinstall.sh - Hermetic unit tests for the cross-cutting
# helpers in linuxinstall.sh (no sudo, no I/O, no /etc).
#
# Strategy: extract a slice of linuxinstall.sh between two known anchors
# into a temp file and source that.  This gives us real definitions of
# _should_run_step, _valid_step, _tmpfile, and the helper variables
# (DRY_RUN, STEP_MODE, SELECTED_STEP) without sourcing the whole 2k-line
# script (which would try to run as root, prompt for env, etc.).
#
# Run: bash tests/test_linuxinstall.sh
set -u
PASS=0; FAIL=0
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_BLD=$'\033[1;37m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_BLD=""; C_RST=""; fi

ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$C_RST" "$1" "$2"; FAIL=$((FAIL+1)); }

# Repo root is the parent of tests/.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/linuxinstall.sh"
[ -f "$SRC" ] || { echo "linuxinstall.sh not found at $SRC"; exit 2; }

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

# Extract the helper block: everything from `_should_run_step() {` up to
# (but not including) the first `ENV_TYPE=""` line.  That gives us:
# _should_run_step, _VALID_STEPS, _valid_step, _tmpfile, and the
# DRY_RUN/STEP_MODE/SELECTED_STEP assignments.
START=$(grep -n '^_should_run_step() {' "$SRC" | head -1 | cut -d: -f1)
END=$(grep -n '^ENV_TYPE=""' "$SRC" | head -1 | cut -d: -f1)
[ -n "$START" ] && [ -n "$END" ] && [ "$END" -gt "$START" ] \
  || { echo "Could not locate helper block in $SRC"; exit 2; }
END=$((END - 1))
sed -n "${START},${END}p" "$SRC" > "$WD/helpers.sh"
# shellcheck disable=SC1090
. "$WD/helpers.sh"

# --- _valid_step: every documented alias must be accepted ---
EXPECTED_KEYS="system system_update dns dnscrypt firewall tor ssh ssh_hardening fail2ban unattended ipv6 sysctl apparmor pam optimize optimize_asr deepclean"
for k in $EXPECTED_KEYS; do
  if _valid_step "$k"; then
    ok_t "_valid_step accepts: $k"
  else
    fail_t "_valid_step accepts: $k" "rejected (this is a bug -- the step exists in main())"
  fi
done

for bad in "FOO" "firewAll" "sshd" "optimizeall" "../etc" ""; do
  if _valid_step "$bad"; then
    fail_t "_valid_step rejects: $bad" "accepted (should be rejected)"
  else
    ok_t "_valid_step rejects: $bad"
  fi
done

# --- _should_run_step: respects STEP_MODE and SELECTED_STEP ---
STEP_MODE=0; SELECTED_STEP=""
if _should_run_step "firewall"; then
  ok_t "_should_run_step: STEP_MODE=0 returns 0 regardless of key"
else
  fail_t "_should_run_step: STEP_MODE=0 returns 0" "got rc=1"
fi

STEP_MODE=1; SELECTED_STEP="firewall"
if _should_run_step "firewall"; then
  ok_t "_should_run_step: STEP_MODE=1, matching key returns 0"
else
  fail_t "_should_run_step: matching key returns 0" "got rc=1"
fi

STEP_MODE=1; SELECTED_STEP="firewall"
if _should_run_step "tor"; then
  fail_t "_should_run_step: non-matching key returns 1" "got rc=0 (bug)"
else
  ok_t "_should_run_step: STEP_MODE=1, non-matching key returns 1"
fi

STEP_MODE=1; SELECTED_STEP=""
if _should_run_step "firewall"; then
  fail_t "_should_run_step: empty SELECTED_STEP skips everything" "got rc=0"
else
  ok_t "_should_run_step: STEP_MODE=1 with empty SELECTED_STEP returns 1"
fi

# --- _tmpfile: returns unique writable file with 0600 perms ---
_TMP_FILES=()
F1=$(_tmpfile)
F2=$(_tmpfile)
if [ -n "$F1" ] && [ -n "$F2" ] && [ "$F1" != "$F2" ] && [ -f "$F1" ] && [ -f "$F2" ]; then
  ok_t "_tmpfile: returns unique writable paths"
else
  fail_t "_tmpfile: returns unique writable paths" "F1=$F1 F2=$F2"
fi

# Verify 0600 permissions (Linux and macOS differ in stat flags).
PERMS=$(stat -c '%a' "$F1" 2>/dev/null || stat -f '%Lp' "$F1" 2>/dev/null)
if [ "$PERMS" = "600" ]; then
  ok_t "_tmpfile: file is 0600 (owner-only)"
else
  fail_t "_tmpfile: file is 0600" "got: $PERMS"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d test(s) passed.%s\n' "$C_GRN" "$TOTAL" "$C_RST"; exit 0
else
  printf '%s%d of %d test(s) failed.%s\n' "$C_RED" "$FAIL" "$TOTAL" "$C_RST"; exit 1
fi
