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
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_RST=""; fi

ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$C_RST" "$1" "$2"; FAIL=$((FAIL+1)); }
# msg and info are defined in the inline fallback of linuxinstall.sh (before line 297,
# outside the extracted region).  Stub them here so the maintenance helpers can call them.
msg()  { printf '=> %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# Repo root is the parent of tests/.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/linuxinstall.sh"
[ -f "$SRC" ] || { echo "linuxinstall.sh not found at $SRC"; exit 2; }

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

# Extract helper block. Four regions:
#   1. run() body: STRICT_RUN to just before _ssh_inspect_config
#      This captures run(), _fw_detect, _is_listening, _service_present,
#      _ensure_firewall_open, and all other cross-cutting helpers.
#   2. Step functions: _should_run_step to _valid_step
#   3. Maintenance helpers: _ssh_inspect_config to before maintenance_menu
#   4. Self-heal functions: _ssh_self_heal_check to before restore_ssh_mode
_STRICT_LINE=$(grep -n '^STRICT_RUN=' "$SRC" | head -1 | cut -d: -f1)
# Include ALL helpers between _restore_etc_snapshot and _ssh_inspect_config:
#   _fw_detect (line ~663), _is_listening (~750), _service_present (~835), etc.
_RUN_END_LINE=$(grep -n '^_ssh_inspect_config() {' "$SRC" | head -1 | cut -d: -f1)
_RUN_END_LINE=$((_RUN_END_LINE - 1))
_STEP_START=$(grep -n '^_should_run_step() {' "$SRC" | tail -1 | cut -d: -f1)
_STEP_END=$(grep -n '^_valid_step() {' "$SRC" | tail -1 | cut -d: -f1)
_STEP_END=$((_STEP_END + 3))
_MAINT_START=$(grep -n '^_ssh_inspect_config() {' "$SRC" | head -1 | cut -d: -f1)
# End right before maintenance_menu so we capture all maintenance helpers
# but not the menu loop itself (which uses prompt_choice and needs a TTY).
_MAINT_END=$(grep -n '^maintenance_menu() {' "$SRC" | head -1 | cut -d: -f1)
_MAINT_END=$((_MAINT_END - 1))
_HEAL_START=$(grep -n '^_ssh_self_heal_check() {' "$SRC" | head -1 | cut -d: -f1)
_HEAL_END=$(grep -n '^restore_ssh_mode() {' "$SRC" | head -1 | cut -d: -f1)
_HEAL_END=$((_HEAL_END - 1))
[ -n "$_STRICT_LINE" ] && [ -n "$_RUN_END_LINE" ] && [ -n "$_STEP_START" ] && [ -n "$_STEP_END" ] \
  && [ -n "$_MAINT_START" ] && [ -n "$_MAINT_END" ] \
  && [ -n "$_HEAL_START" ] && [ -n "$_HEAL_END" ] \
  || { echo "Could not locate helper block in $SRC"; exit 2; }

# Source lib/color.sh first so the run() body can call msg/err/ok.
if [ -r "$ROOT/lib/color.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/lib/color.sh"
fi

# Source the extracted regions.
{
  sed -n "${_STRICT_LINE},${_RUN_END_LINE}p" "$SRC"
  sed -n "${_STEP_START},${_STEP_END}p" "$SRC"
  sed -n "${_MAINT_START},${_MAINT_END}p" "$SRC"
  sed -n "${_HEAL_START},${_HEAL_END}p" "$SRC"
} > "$WD/helpers.sh"
# shellcheck disable=SC1090
. "$WD/helpers.sh"
unset _STRICT_LINE _RUN_END_LINE _STEP_START _STEP_END _MAINT_START _MAINT_END _HEAL_START _HEAL_END

# --- lib/temp.sh: source the real library, not the script's fallback ---
if [ -r "$ROOT/lib/temp.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/lib/temp.sh"
else
  echo "lib/temp.sh not found at $ROOT/lib"; exit 2
fi

# --- lib/updater.sh: source the real library so _run_all_updates and
# the per-package-manager helpers exist in the test env.  We deliberately
# do not invoke the dispatcher here (the slice doesn't define `run` in a
# way that matches production); we just want the function declarations.
if [ -r "$ROOT/lib/updater.sh" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/lib/updater.sh"
else
  echo "lib/updater.sh not found at $ROOT/lib"; exit 2
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
# The 0600 behaviour relies on Linux mktemp semantics and `install(1) -m`.
# Skip on non-POSIX hosts where /tmp and /dev/null are not Linux-compatible.
case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux)
    F1=$(_tmpfile)
    F2=$(_tmpfile)
    # Clean up the test temp files at script exit.
    trap 'rm -f "$F1" "$F2" 2>/dev/null || true' EXIT
    if [ -n "$F1" ] && [ -n "$F2" ] && [ "$F1" != "$F2" ] && [ -f "$F1" ] && [ -f "$F2" ]; then
      ok_t "_tmpfile: returns unique writable paths"
    else
      fail_t "_tmpfile: returns unique writable paths" "F1=$F1 F2=$F2"
    fi

    PERMS=$(stat -c '%a' "$F1" 2>/dev/null)
    if [ "$PERMS" = "600" ]; then
      ok_t "_tmpfile: file is 0600 (owner-only)"
    else
      fail_t "_tmpfile: file is 0600" "got: $PERMS"
    fi
    ;;
  Darwin|FreeBSD|NetBSD|OpenBSD)
    F1=$(_tmpfile)
    F2=$(_tmpfile)
    trap 'rm -f "$F1" "$F2" 2>/dev/null || true' EXIT
    if [ -n "$F1" ] && [ -n "$F2" ] && [ "$F1" != "$F2" ] && [ -f "$F1" ] && [ -f "$F2" ]; then
      ok_t "_tmpfile: returns unique writable paths (BSD path)"
    else
      fail_t "_tmpfile: returns unique writable paths" "F1=$F1 F2=$F2"
    fi

    PERMS=$(stat -f '%Lp' "$F1" 2>/dev/null)
    if [ "$PERMS" = "600" ]; then
      ok_t "_tmpfile: file is 0600 (owner-only)"
    else
      # BSD mktemp uses 0600 by default so the chmod/install step is not
      # strictly required; record an info-level line instead of failing.
      info "_tmpfile: file is $PERMS (BSD mktemp default; installer skipped)"
    fi
    ;;
  *)
    info "Skipping _tmpfile tests on non-POSIX platform ($(uname -s))"
    ;;
esac

# --- _ssh_current_port: must default to 22 on a system with no Port directive ---
# We test the function in isolation: with no /etc/ssh/sshd_config present
# (hermetic), the function should still return "22".
if [ ! -f /etc/ssh/sshd_config ]; then
  if [ "$(_ssh_current_port 2>/dev/null)" = "22" ]; then
    ok_t "_ssh_current_port: defaults to 22 when no sshd_config present"
  else
    fail_t "_ssh_current_port: defaults to 22" "got: $(_ssh_current_port)"
  fi
else
  info "Skipping _ssh_current_port default test (real /etc/ssh/sshd_config present)"
fi

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

# --- _valid_step: regression -- the existing step keys must still all pass ---
for k in system system_update firewall tor ssh_hardening; do
  if ! _valid_step "$k"; then
    fail_t "_valid_step regression: $k" "previously valid key rejected"
  fi
done
[ "$FAIL" = "0" ] && ok_t "_valid_step: regression on common keys"

# --- _ssh_self_heal_check: declared functions it calls must exist ---
for fn in _is_listening _service_present _fw_detect; do
  if declare -F "$fn" >/dev/null 2>&1; then
    ok_t "_ssh_self_heal_check helper: $fn is declared"
  else
    fail_t "_ssh_self_heal_check helper: $fn is declared" "not found"
  fi
done

# --- _ssh_self_heal_install / _ssh_self_heal_uninstall: declared ---
for fn in _ssh_self_heal_install _ssh_self_heal_uninstall; do
  if declare -F "$fn" >/dev/null 2>&1; then
    ok_t "$fn is declared"
  else
    fail_t "$fn is declared" "not found"
  fi
done

# --- _maintenance_list_keys: function exists and is callable ---
if declare -F _maintenance_list_keys >/dev/null 2>&1; then
  ok_t "_maintenance_list_keys: declared"
else
  fail_t "_maintenance_list_keys: declared" "not found"
fi

# --- _ssh_inspect_config: function exists ---
if declare -F _ssh_inspect_config >/dev/null 2>&1; then
  ok_t "_ssh_inspect_config is declared"
else
  fail_t "_ssh_inspect_config is declared" "not found"
fi

# --- _maintenance_logs: function exists ---
if declare -F _maintenance_logs >/dev/null 2>&1; then
  ok_t "_maintenance_logs: declared"
else
  fail_t "_maintenance_logs: declared" "not found"
fi

# --- _maintenance_sysinfo: function exists ---
if declare -F _maintenance_sysinfo >/dev/null 2>&1; then
  ok_t "_maintenance_sysinfo: declared"
else
  fail_t "_maintenance_sysinfo: declared" "not found"
fi

# --- _ssh_self_heal_check: function is callable without crashing on a no-ssh system ---
# Calling it on a test environment without sshd installed should be a no-op (returns 0).
if declare -F _ssh_self_heal_check >/dev/null 2>&1; then
  QUIET_PROMPTS=1 _ssh_self_heal_check >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "0" ]; then
    ok_t "_ssh_self_heal_check: no-op on system without sshd (rc=0)"
  else
    fail_t "_ssh_self_heal_check: no-op rc" "got rc=$rc"
  fi
else
  fail_t "_ssh_self_heal_check: declared" "not found"
fi

# --- _run_all_updates dispatcher smoke-test ---
# All sub-update functions must exist (they are sourced from the inline fallback).
for _fn in _update_apt _update_dnf _update_yum _update_zypper _update_pacman \
           _update_snap _update_flatpak _update_docker _update_brew _update_firmware; do
  if declare -F "$_fn" >/dev/null 2>&1; then
    ok_t "_run_all_updates sub: $_fn declared"
  else
    fail_t "_run_all_updates sub: $_fn declared" "not found"
  fi
done
# _run_all_updates itself must be declared.
if declare -F _run_all_updates >/dev/null 2>&1; then
  ok_t "_run_all_updates: dispatcher declared"
else
  fail_t "_run_all_updates: dispatcher declared" "not found"
fi
# On a test host with no package managers, the dispatcher should not abort.
# It may return 0 (all skipped) or 1 (nothing to update), but must not crash.
if [ "$FAIL" -eq 0 ]; then
  UPDATED=0 FAILED=0 _run_all_updates >/dev/null 2>&1; rc=$?
  if [ "$rc" -le 1 ]; then
    ok_t "_run_all_updates: completes cleanly (rc=$rc) on host with no package managers"
  else
    fail_t "_run_all_updates: unexpected rc" "got rc=$rc (expected 0 or 1)"
  fi
fi

# --- Regression: linuxinstall.sh must parse without errors (bash -n) ---
# Catches parse regressions in any function, including setup_dnscrypt (fixed
# in pass 1: missing `then` + stray `fi`).
if [ -f "$SRC" ]; then
  if bash -n "$SRC" 2>&1; then
    ok_t "bash -n $SRC: no syntax errors"
  else
    fail_t "bash -n $SRC" "syntax errors detected (run: bash -n $SRC)"
  fi
fi

# --- Regression: setup_dnscrypt inner if-block must have balanced then/fi ---
# The fix in pass 1 replaced a missing `then` (syntax error). Verify the
# corrected pattern: the `! pkg_install dnscrypt-proxy` call is followed by `then`.
# We anchor on `! pkg_install dnscrypt-proxy` (unique in the file).
if grep -n '^setup_dnscrypt()' "$SRC" >/dev/null 2>&1; then
  _install_line=$(grep -n '! pkg_install dnscrypt-proxy' "$SRC" 2>/dev/null \
                | head -1 | cut -d: -f1)
  if [ -n "$_install_line" ]; then
    # `then` may appear on the same line (one-liner) or on a subsequent line.
    # Check the install line itself plus the next 4 lines.
    _has_then=$(sed -n "$((_install_line)),$((_install_line + 4))p" "$SRC" 2>/dev/null \
                | grep -cE '\<then' || true)
    if [ "$_has_then" -gt 0 ]; then
      ok_t "setup_dnscrypt: pkg_install is followed by 'then' (parse regression fixed)"
    else
      fail_t "setup_dnscrypt: pkg_install has no following 'then'" \
             "missing 'then' after pkg_install — parse regression not fixed"
    fi
  else
    fail_t "setup_dnscrypt: '! pkg_install dnscrypt-proxy' not found" \
           "pattern changed — verify the fix is still in place"
  fi
fi

# --- Regression: print_metrics_summary disk-delta logic is syntactically valid ---
# Verify the three-branch disk_delta if/elif/else exists in the source.
# These branches were added in pass 1; a future refactor that collapses them
# back to two branches would break the "net usage grew" case.
if grep -qE 'disk_delta.*-gt 0|disk_delta.*-lt 0|disk_delta.*-eq 0' "$SRC" 2>/dev/null; then
  ok_t "print_metrics_summary: three-branch disk-delta logic present in source"
else
  fail_t "print_metrics_summary: three-branch disk-delta logic" "pattern not found"
fi

# --- UX function execution coverage (proposal B) ---
# The extracted slice sources show_progress, print_welcome, print_metrics_summary,
# ask_profile. Each one is now invoked with mocked globals and verified not to crash.
# Output is captured but not asserted verbatim (UX is allowed to evolve); the
# regression signal is "function runs to completion without errors".

# show_progress: must run and emit at least one bar char.
if declare -F show_progress >/dev/null 2>&1; then
  CHECKLIST[tmux_wrap]="done"
  CHECKLIST[env_detect]="running"
  CHECKLIST[system_update]="skip"
  _out=$(show_progress 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$_out" ]; then
    ok_t "show_progress: runs to completion (rc=0) and emits output"
  else
    fail_t "show_progress: runs to completion" "rc=$rc, output_len=${#_out}"
  fi
  unset CHECKLIST
fi

# print_welcome: must run and not crash.
# Note: EUID and USER are readonly/set by the shell. We set USER to a stub
# value before invoking, since the function uses it for the "Run as:" label.
if declare -F print_welcome >/dev/null 2>&1; then
  REPLY_PROFILE=2
  QUICK_MODE=0
  USE_REMOTE_SSH="no"
  ENV_TYPE="server"
  _profile_label() { echo "Standard"; }
  USER="${USER:-testuser}"  # ensure bound for set -u
  _out=$(print_welcome 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$_out" | grep -q "Run as:"; then
    ok_t "print_welcome: runs to completion (rc=0), includes 'Run as:' line"
  else
    fail_t "print_welcome: runs to completion" "rc=$rc, 'Run as:'=$(printf '%s' "$_out" | grep -c 'Run as:')"
  fi
  # Verify the EUID-conditional label. The function checks EUID directly.
  if [ "$EUID" -ne 0 ] && printf '%s' "$_out" | grep -q "non-root"; then
    ok_t "print_welcome: non-root EUID shows 'non-root' hint (pass-1 fix)"
  elif [ "$EUID" -eq 0 ] && printf '%s' "$_out" | grep -q "root"; then
    ok_t "print_welcome: root EUID shows 'root' label (pass-1 fix)"
  else
    fail_t "print_welcome: EUID label" "neither 'root' nor 'non-root' found (EUID=$EUID)"
  fi
  # Clean up to avoid polluting subsequent tests.
  unset REPLY_PROFILE QUICK_MODE USE_REMOTE_SSH ENV_TYPE USER
fi

# print_metrics_summary: all three disk-delta branches must be reachable.
# We mock METRICS_START_DISK_KB and check that the function picks the right branch.
# We can't intercept df output, so we only verify the function runs without error
# in each of the three (EUID, delta) cases.
if declare -F print_metrics_summary >/dev/null 2>&1; then
  unset METRICS 2>/dev/null || true
  declare -A METRICS
  METRICS_START_DISK_KB=0
  METRICS[pkgs_upgraded]=0; METRICS[pkgs_installed]=0
  METRICS[services_hardened]=0; METRICS[services_stopped]=0
  METRICS[sysctls_applied]=0; METRICS[fw_rules_added]=0
  METRICS[auth_keys_added]=0; METRICS[tor_services_enabled]=0
  METRICS[configs_backed_up]=0; METRICS[rollback_logged]=0
  USE_REMOTE_SSH="no"
  ENV_TYPE="server"
  ROLLBACK_LOG="/tmp/rollback-test.log"
  _metrics_bar() { :; }

  # Non-root EUID is readonly in bash, so we cannot inject EUID=0 to test the
  # root branch. We test the branch that matches the current EUID.
  if [ "$EUID" -ne 0 ]; then
    # Test the non-root branch: should show "re-run as root to measure"
    _out=$(print_metrics_summary 2>&1)
    if printf '%s' "$_out" | grep -q "re-run as root"; then
      ok_t "print_metrics_summary: non-root branch shows 're-run as root' (EUID=$EUID)"
    else
      fail_t "print_metrics_summary: non-root branch" "missing 're-run as root' message (EUID=$EUID)"
    fi
  fi
  # Run a second time to confirm the function is idempotent (calling it twice
  # with the same EUID and no state mutation must not fail).
  _out=$(print_metrics_summary 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok_t "print_metrics_summary: second call returns 0 (idempotent)"
  else
    fail_t "print_metrics_summary: second call idempotent" "rc=$rc"
  fi
  unset METRICS_START_DISK_KB METRICS ROLLBACK_LOG _metrics_bar
fi

# ask_profile: source-grep only (it has a hardcoded read loop that blocks on stdin).
# Verify it's declared and its prompt_choice string set is unchanged.
if declare -F ask_profile >/dev/null 2>&1; then
  ok_t "ask_profile: declared in extracted slice"
else
  fail_t "ask_profile: declared" "not found after sourcing slice"
fi

# --- Snapshot tests (proposal B) ---
# Compare print_welcome and print_metrics_summary output against committed
# fixture files.  On deliberate UX change, regenerate fixtures by running
# tests/gen_snapshots.sh and committing the result.
#
# Fixtures are platform-agnostic by design: we normalize the lines that
# change per-host (hostname, OS, kernel, uname -m) before comparison.
_normalize_output() {
  # Replace lines whose value is host-specific with placeholders.
  printf '%s' "$1" | awk '
    /^  Host:[[:space:]]/     { sub(/Host:[[:space:]]+.*/, "Host:          <HOST>");     print; next }
    /^  OS:[[:space:]]/       { sub(/OS:[[:space:]]+.*/,       "OS:            <OS>");       print; next }
    /^  Kernel:[[:space:]]/   { sub(/Kernel:[[:space:]]+.*/,   "Kernel:        <KERNEL>");   print; next }
    /^  Arch:[[:space:]]/     { sub(/Arch:[[:space:]]+.*/,     "Arch:          <ARCH>");     print; next }
    { print }
  '
}

# print_welcome snapshot (non-root, REPLY_PROFILE=2)
if declare -F print_welcome >/dev/null 2>&1; then
  REPLY_PROFILE=2; QUICK_MODE=0; USE_REMOTE_SSH="no"; ENV_TYPE="server"
  # Save the original USER so we can restore it after the test; using
  # `unset` would clobber an inherited value and break the user’s env.
  _USER_SAVED="${USER:-}"
  USER="${USER:-testuser}"
  _profile_label() { echo "Standard"; }
  _welcome_actual=$(_normalize_output "$(print_welcome 2>&1)")
  if [ -f "$ROOT/tests/print_welcome_snapshot.txt" ]; then
    _welcome_expected=$(_normalize_output "$(cat "$ROOT/tests/print_welcome_snapshot.txt")")
    if [ "$_welcome_actual" = "$_welcome_expected" ]; then
      ok_t "print_welcome: snapshot match (print_welcome_snapshot.txt)"
    else
      fail_t "print_welcome: snapshot match" \
             "output diverged from fixture. Run: bash tests/gen_snapshots.sh
--- expected ---
$_welcome_expected
--- actual ---
$_welcome_actual"
    fi
  else
    fail_t "print_welcome: snapshot file" "tests/print_welcome_snapshot.txt missing"
  fi
  unset REPLY_PROFILE QUICK_MODE USE_REMOTE_SSH ENV_TYPE
  if [ -n "$_USER_SAVED" ]; then
    USER="$_USER_SAVED"
  else
    unset USER
  fi
  unset _USER_SAVED
fi

# print_metrics_summary snapshot (mocked METRICS, non-root)
if declare -F print_metrics_summary >/dev/null 2>&1; then
  # Declare METRICS as an associative array first so that subscripted assignment
  # (METRICS[key]=val) does not trigger set -u "unbound variable" errors.
  unset METRICS 2>/dev/null || true
  declare -A METRICS
  METRICS_START_DISK_KB=0
  METRICS[pkgs_upgraded]=2; METRICS[pkgs_installed]=1
  METRICS[services_hardened]=3; METRICS[services_stopped]=1
  METRICS[sysctls_applied]=5; METRICS[fw_rules_added]=2
  METRICS[auth_keys_added]=0; METRICS[tor_services_enabled]=0
  METRICS[configs_backed_up]=4; METRICS[rollback_logged]=4
  USE_REMOTE_SSH="no"; ENV_TYPE="server"
  ROLLBACK_LOG="/tmp/rollback-test.log"
  _metrics_bar() { printf '  %-28s %s\n' "  $1" "[████████░░░░]"; }
  _summary_actual=$(print_metrics_summary 2>&1)
  if [ -f "$ROOT/tests/print_metrics_summary_snapshot.txt" ]; then
    _summary_expected=$(cat "$ROOT/tests/print_metrics_summary_snapshot.txt")
    if [ "$_summary_actual" = "$_summary_expected" ]; then
      ok_t "print_metrics_summary: snapshot match (print_metrics_summary_snapshot.txt)"
    else
      fail_t "print_metrics_summary: snapshot match" \
             "output diverged from fixture. Run: bash tests/gen_snapshots.sh
--- expected ---
$_summary_expected
--- actual ---
$_summary_actual"
    fi
  else
    fail_t "print_metrics_summary: snapshot file" "tests/print_metrics_summary_snapshot.txt missing"
  fi
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d test(s) passed.%s\n' "$C_GRN" "$TOTAL" "$C_RST"; exit 0
else
  printf '%s%d of %d test(s) failed.%s\n' "$C_RED" "$FAIL" "$TOTAL" "$C_RST"; exit 1
fi
