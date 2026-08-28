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

# Extract helper block. Two non-contiguous regions:
#   1. STRICT_RUN / _FAIL_COUNT / run() body (lines 164-182)
#   2. _should_run_step / _VALID_STEPS / _valid_step (lines 683-705)
# We concatenate both into a single sourced file. Anchors are line numbers
# from grep -n; resilient to small edits above each anchor.
_STRICT_LINE=$(grep -n '^STRICT_RUN=' "$SRC" | head -1 | cut -d: -f1)
_RUN_END_LINE=$(grep -n '^_restore_etc_snapshot() {' "$SRC" | head -1 | cut -d: -f1)
_RUN_END_LINE=$((_RUN_END_LINE - 1))
_STEP_START=$(grep -n '^_should_run_step() {' "$SRC" | tail -1 | cut -d: -f1)
_STEP_END=$(grep -n '^_valid_step() {' "$SRC" | tail -1 | cut -d: -f1)
# _valid_step is a 4-line function; grab 3 more lines past the signature.
_STEP_END=$((_STEP_END + 3))
[ -n "$_STRICT_LINE" ] && [ -n "$_RUN_END_LINE" ] && [ -n "$_STEP_START" ] && [ -n "$_STEP_END" ] \
  || { echo "Could not locate helper block in $SRC"; exit 2; }

# Source lib/color.sh first so the run() body can call msg/err/ok.
if [ -r "$ROOT/lib/color.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/lib/color.sh"
fi

# Source the two extracted regions.
{
  sed -n "${_STRICT_LINE},${_RUN_END_LINE}p" "$SRC"
  sed -n "${_STEP_START},${_STEP_END}p" "$SRC"
} > "$WD/helpers.sh"
# shellcheck disable=SC1090
. "$WD/helpers.sh"
unset _STRICT_LINE _RUN_END_LINE _STEP_START _STEP_END

# --- lib/temp.sh: source the real library, not the script's fallback ---
if [ -r "$ROOT/lib/temp.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/lib/temp.sh"
else
  echo "lib/temp.sh not found at $ROOT/lib"; exit 2
fi

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

# Verify 0600 permissions. Skip on platforms where chmod is a no-op
# (e.g. Git Bash on Windows: /tmp maps to a Windows temp directory and
# Cygwin's chmod is best-effort). mktemp on real Linux defaults to 0600.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) printf '  -- %s\n' "_tmpfile 0600: skipped on Windows mktemp" ;;
  *)
    PERMS=$(stat -c '%a' "$F1" 2>/dev/null || stat -f '%Lp' "$F1" 2>/dev/null)
    if [ "$PERMS" = "600" ]; then
      ok_t "_tmpfile: file is 0600 (owner-only)"
    else
      fail_t "_tmpfile: file is 0600" "got: $PERMS"
    fi
    ;;
esac

# --- DRY_RUN: run() must print DRY: and NOT execute the command ---
# (run is defined in the sourced helpers above. Tests must not wrap run()
# in $(...) because variables like _FAIL_COUNT set inside the subshell
# are lost when the subshell exits.)
DRY_RUN=1 _FAIL_COUNT=0
out=""
rc=0
out=$(DRY_RUN=1 run echo "this should not run" 2>&1); rc=$?
# When run() hits the DRY_RUN branch it prints "  DRY: <args>" and returns 0
# without ever invoking the command. Compare against the full string the
# script's `run` produces (note the 2-space indent from the source).
if [ "$rc" -eq 0 ] && [ "$out" = "  DRY: echo this should not run" ]; then
  ok_t "DRY_RUN=1: run prints DRY: prefix and returns 0"
else
  fail_t "DRY_RUN=1: run prints DRY: prefix and returns 0" "rc=$rc out='$out'"
fi

# DRY_RUN=0: run() executes the command and always returns 0 (non-strict).
DRY_RUN=0 _FAIL_COUNT=0
rc=0
run true; rc=$?
if [ "$rc" -eq 0 ] && [ "$_FAIL_COUNT" -eq 0 ]; then
  ok_t "DRY_RUN=0: run executes true and returns 0"
else
  fail_t "DRY_RUN=0: run executes true and returns 0" "rc=$rc _FAIL_COUNT=$_FAIL_COUNT"
fi

# DRY_RUN=0 with a failing command: run() returns 0 (non-strict) but increments _FAIL_COUNT.
DRY_RUN=0 STRICT_RUN=0 _FAIL_COUNT=0
rc=0
run false; rc=$?
if [ "$rc" -eq 0 ] && [ "$_FAIL_COUNT" -eq 1 ]; then
  ok_t "DRY_RUN=0: run(false) increments _FAIL_COUNT but returns 0"
else
  fail_t "DRY_RUN=0: run(false) increments _FAIL_COUNT but returns 0" "rc=$rc _FAIL_COUNT=$_FAIL_COUNT"
fi

# STRICT_RUN=1 with a failing command: run() returns the actual exit code.
DRY_RUN=0 STRICT_RUN=1 _FAIL_COUNT=0
rc=0
run false; rc=$?
if [ "$rc" -ne 0 ] && [ "$_FAIL_COUNT" -eq 1 ]; then
  ok_t "STRICT_RUN=1: run(false) returns non-zero exit code"
else
  fail_t "STRICT_RUN=1: run(false) returns non-zero exit code" "rc=$rc _FAIL_COUNT=$_FAIL_COUNT"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d test(s) passed.%s\n' "$C_GRN" "$TOTAL" "$C_RST"; exit 0
else
  printf '%s%d of %d test(s) failed.%s\n' "$C_RED" "$FAIL" "$TOTAL" "$C_RST"; exit 1
fi
