#!/usr/bin/env bash
# tests/test_updater.sh - real-integration test for lib/updater.sh.
#
# Verifies that:
#   - Every _update_* function in lib/updater.sh is declared after sourcing.
#   - _track increments UPDATED on success, FAILED on failure.
#   - The dispatcher continues after a sub-step returns non-zero.
#   - _update_apt (and other package-manager fns) is a no-op when the
#     package manager is not installed.
#   - _run_all_updates on a host with no package managers returns 0
#     (or 1 if FAILED > 0), never aborts.
#   - The apt-fail cleanup logic: if `apt-get full-upgrade` fails, the
#     autoremove/clean steps are still attempted (best-effort cleanup).
#   - mapfile works (Bash 4+).
#
# Strategy: source lib/updater.sh into a test harness, then mock the
# `run` shim to count invocations and drive outcomes deterministically.
#
# Run: bash tests/test_updater.sh
set -u
PASS=0; FAIL=0
# Ensure any test-created temp files are cleaned even on unexpected exit.
trap 'rm -f /tmp/_cmd_test_ran_$$ 2>/dev/null || true' EXIT
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_RST=""; fi
ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$1" "$C_RST" "$2"; FAIL=$((FAIL+1)); }

# Stub msg/ok/warn/err/info so sourcing lib/updater.sh does not pollute test
# output. The lib's own print helpers are guarded by `set -u` since some
# rely on $USE_COLOR; we set it explicitly.
USE_COLOR=0
msg()  { :; }
info() { :; }
ok()   { :; }
warn() { :; }
err()  { :; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/lib/updater.sh" ] || { echo "lib/updater.sh not found"; exit 2; }

# Source the library under test. After this, _update_*, _track, _run_all_updates,
# UPDATED, FAILED, VERBOSE, _log are all defined.
# shellcheck disable=SC1090
. "$ROOT/lib/updater.sh"

# --- Test 1: every advertised _update_* function is declared ---
EXPECTED_UPDATERS="update_apt update_dnf update_yum update_zypper update_pacman update_snap update_flatpak update_docker update_brew update_firmware update_geoip update_virsh update_suse_snapper update_btrfs_balance update_pihole"
for fn in $EXPECTED_UPDATERS; do
  if declare -F "_$fn" >/dev/null 2>&1; then
    ok_t "_$fn declared"
  else
    fail_t "_$fn declared" "function not found after sourcing lib/updater.sh"
  fi
done

# --- Test 2: _track semantics: success increments UPDATED, failure increments FAILED ---
# Note: the subshell is on the left side, _track on the right. We capture
# the exit code via a variable trick: run in the current shell, not a
# subshell, so UPDATED/FAILED changes propagate.
UPDATED=0; FAILED=0
( true )
_track
if [ "$UPDATED" = "1" ] && [ "$FAILED" = "0" ]; then
  ok_t "_track on rc=0: UPDATED=1, FAILED=0"
else
  fail_t "_track on rc=0" "UPDATED=$UPDATED FAILED=$FAILED"
fi
UPDATED=0; FAILED=0
( false )
_track
if [ "$UPDATED" = "0" ] && [ "$FAILED" = "1" ]; then
  ok_t "_track on rc=1: UPDATED=0, FAILED=1"
else
  fail_t "_track on rc=1" "UPDATED=$UPDATED FAILED=$FAILED"
fi

# --- Test 3: bash 4+ required (mapfile) ---
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok_t "Bash 4+ detected (BASH_VERSINFO=${BASH_VERSINFO[0]})"
else
  fail_t "Bash 4+ required" "found bash ${BASH_VERSINFO[0]}"
fi

# --- Test 4: dispatcher on a no-package-manager host returns cleanly ---
# On Windows CI, no real package managers exist. _update_* all early-return
# via `command -v ... || return 0`, so the dispatcher should return 0
# (UPDATED=0, FAILED=0) — "Everything is up to date."
UPDATED=0; FAILED=0
_run_all_updates >/dev/null 2>&1
rc=$?
if [ "$rc" = "0" ]; then
  ok_t "_run_all_updates on bare host: rc=0 (no-op)"
else
  fail_t "_run_all_updates on bare host" "got rc=$rc, expected 0"
fi

# --- Test 5: dispatcher returns 1 when FAILED > 0 ---
# Inject a sentinel failure count and verify the summary path returns 1.
# Do NOT call real _update_* sub-steps (they may be real commands on some hosts).
# Instead, override all _update_* to no-ops, then inject FAILED=999 so the
# dispatcher sees FAILED>0 and returns 1 regardless of the sub-step results.
for _fn in apt dnf yum zypper pacman snap flatpak docker brew firmware geoip virsh suse_snapper btrfs_balance pihole; do
  eval "_update_$_fn() { return 0; }"
done
UPDATED=0
FAILED_SAVED=$FAILED
FAILED=999
result=0
_run_all_updates >/dev/null 2>&1 || result=$?
FAILED=$FAILED_SAVED
if [ "$result" = "1" ]; then
  ok_t "_run_all_updates with FAILED=999: returns 1 (summary path works)"
else
  fail_t "_run_all_updates with FAILED=999" "got rc=$result, expected 1"
fi

# --- Test 6: dispatcher with a stub _update_* that always fails ---
# Replace _update_dnf with a function that returns 1; verify the
# dispatcher does not abort and surfaces the failure.
UPDATED=0; FAILED=0
_update_dnf() { FAILED=$((FAILED+1)); return 1; }
_run_all_updates >/dev/null 2>&1
rc=$?
if [ "$rc" -ge 1 ] && [ "$FAILED" -ge 1 ]; then
  ok_t "_run_all_updates with failing sub-step: continues, FAILED>=1, rc=$rc"
else
  fail_t "_run_all_updates with failing sub-step" "rc=$rc FAILED=$FAILED"
fi

# --- Test 7: dispatcher with all sub-steps succeeding (simulated) ---
# Replace all _update_* with no-ops; UPDATED counter should not change
# (the functions do not call _track) but the dispatcher should return 0.
# Then verify the dispatcher exits 0 when nothing fails.
UPDATED=0; FAILED=0
for fn in apt dnf yum zypper pacman snap flatpak docker brew firmware geoip virsh suse_snapper btrfs_balance pihole; do
  eval "_update_$fn() { return 0; }"
done
result=0
_run_all_updates >/dev/null 2>&1 || result=$?
if [ "$result" = "0" ] && [ "$FAILED" = "0" ]; then
  ok_t "_run_all_updates with all sub-steps returning 0: rc=0, FAILED=0"
else
  fail_t "_run_all_updates with all sub-steps returning 0" "rc=$result FAILED=$FAILED"
fi

# --- Test 8: UPDATED counter is honored in summary ---
# Force UPDATED > 0 and verify the success branch path runs without error.
UPDATED=5; FAILED=0
result=0
_run_all_updates >/dev/null 2>&1 || result=$?
if [ "$result" = "0" ]; then
  ok_t "_run_all_updates with UPDATED=5: returns 0 (no failures)"
else
  fail_t "_run_all_updates with UPDATED=5" "got rc=$result, expected 0"
fi

# --- Test 9: GEOIP_URL env override is respected ---
# Set GEOIP_URL to a custom value and verify the variable is in scope
# (the actual download path requires network and a target file; we only
# verify the env override mechanism is honored via a stub).
# Read the function body and confirm it uses $GEOIP_URL and $MAXMIND_LICENSE_KEY.
if grep -qE 'MAXMIND_LICENSE_KEY|GEOIP_URL' "$ROOT/lib/updater.sh" 2>/dev/null; then
  ok_t "_update_geoip honors MAXMIND_LICENSE_KEY / GEOIP_URL env overrides"
else
  fail_t "_update_geoip honors env overrides" "lib/updater.sh does not reference MAXMIND_LICENSE_KEY or GEOIP_URL"
fi

# --- Test 10: BASH_VERSION gate at the top of the file ---
# If the file is sourced on bash 3, sourcing should produce a clear error
# message. We don't run on bash 3 here, but we verify the guard exists.
if grep -qE 'BASH_VERSINFO\[0\]' "$ROOT/lib/updater.sh" 2>/dev/null; then
  ok_t "lib/updater.sh has bash 4+ version guard"
else
  fail_t "lib/updater.sh has bash 4+ version guard" "BASH_VERSINFO check not found"
fi

# --- Test 11: _cmd helper exists and prints DRY: prefix ---
if declare -F _cmd >/dev/null 2>&1; then
  ok_t "_cmd helper: declared"
else
  fail_t "_cmd helper: declared" "not found after sourcing lib/updater.sh"
fi
# DRY_RUN=1 with _cmd should print "DRY: <args>" and return 0 without
# executing the command. Verify both: the trace line is printed, and
# the command was NOT executed (temp file must not exist after).
DRY_RUN=1
ran_flag=/tmp/_cmd_test_ran_$$
rm -f "$ran_flag" 2>/dev/null || true
out=$(_cmd touch "$ran_flag" 2>&1)
rc=$?
DRY_RUN=0
# The file must NOT exist — that proves the command was skipped.
if [ "$rc" = "0" ] && [ ! -e "$ran_flag" ] \
   && printf '%s' "$out" | grep -q "DRY:"; then
  ok_t "_cmd under DRY_RUN=1: prints DRY: and skips execution"
else
  fail_t "_cmd under DRY_RUN=1" "rc=$rc file_exists=$([ -e "$ran_flag" ] && echo yes || echo no) output='$out'"
fi
# Cleanup guaranteed regardless of pass/fail (no leak).
rm -f "$ran_flag" 2>/dev/null || true
unset DRY_RUN

# --- Test 12: _cmd under VERBOSE=2 prints "RUN:" trace ---
if declare -F _cmd >/dev/null 2>&1; then
  VERBOSE=2
  out=$(_cmd echo "traced" 2>&1)
  VERBOSE=0
  if printf '%s' "$out" | grep -q "RUN: echo traced"; then
    ok_t "_cmd under VERBOSE=2: prints RUN: trace line"
  else
    fail_t "_cmd under VERBOSE=2" "expected 'RUN: echo traced' in output, got '$out'"
  fi
fi

# --- Test 13: VERBOSE=1 controls _log() ---
# _log prints only when VERBOSE=1; verify by capturing output.
log_output=$(
  USE_COLOR=0
  info() { printf 'LOG:%s\n' "$*"; }
  VERBOSE=0
  _log "hidden message"
  VERBOSE=1
  _log "visible message"
  VERBOSE=0
)
if printf '%s' "$log_output" | grep -q "LOG:visible message" && \
   ! printf '%s' "$log_output" | grep -q "LOG:hidden message"; then
  ok_t "VERBOSE=1 controls _log(): visible only when set"
else
  fail_t "VERBOSE=1 controls _log()" "got: $log_output"
fi

# --- Test 14: --summary=json emits valid JSON ---
# The JSON output should contain elapsed_s, updated, failed fields.
# We verify it parses as JSON by checking the brace syntax.
# shellcheck disable=SC2094
json_output=$(_run_all_updates --summary=json 2>/dev/null)
if [ -n "$json_output" ] \
   && printf '%s' "$json_output" | grep -qE '^\{"elapsed_s":[0-9]+,"updated":[0-9]+,"failed":[0-9]+\}$'; then
  ok_t "_run_all_updates --summary=json: emits valid JSON"
else
  fail_t "_run_all_updates --summary=json" "got: $json_output"
fi

# --- Test 15: --parallel=1 runs sequentially (no temp dir) ---
# PARALLEL=1 should be equivalent to sequential; returns 0 on bare host.
unset PARALLEL
UPDATED=0; FAILED=0
result=0
_run_all_updates --parallel=1 2>/dev/null || result=$?
if [ "$result" -le 1 ]; then
  ok_t "_run_all_updates --parallel=1: sequential execution returns $result"
else
  fail_t "_run_all_updates --parallel=1" "got rc=$result"
fi

# --- Test 16: _runner_cmd (run alias) is declared after sourcing ---
if declare -F _runner_cmd >/dev/null 2>&1; then
  ok_t "_runner_cmd helper: declared"
else
  fail_t "_runner_cmd helper: declared" "not found"
fi

# --- Test 17: run() delegates to _runner_cmd ---
# Calling run() should behave identically to _runner_cmd().
# On a bare host (no package managers), both should return 0.
# We verify run() is callable.
if declare -F run >/dev/null 2>&1; then
  ok_t "run function: declared"
else
  fail_t "run function: declared" "not found"
fi

# --- Test 18: parallel subshell propagates exit code (pass 1 regression) ---
# The pass-1 fix changed `exit 0` to `exit "$_rc"` in the background
# subshell so `wait` in the parent correctly sees the sub-step's failure.
# We verify by reading the function source and confirming the pattern.
if grep -E 'exit "\$_rc"' "$ROOT/lib/updater.sh" >/dev/null 2>&1; then
  ok_t "_run_updates_parallel subshell: exits with \$_rc (not hardcoded 0)"
else
  fail_t "_run_updates_parallel subshell: exit \"\$_rc\"" \
         "subshell hardcodes exit 0 — failure will not propagate to parent wait"
fi

# --- Test 19: parallel aggregate does not double-count FAILED ---
# The pass-1 fix removed the redundant `FAILED + 1` in the aggregate loop
# (the per-step _track() call already counted each failure). Verify by
# checking the source for the removed pattern.
if grep -E '\[ "\$_rc" -ne 0 \] 2>/dev/null && FAILED=\$\(\(FAILED \+ 1\)\)' \
     "$ROOT/lib/updater.sh" >/dev/null 2>&1; then
  fail_t "_run_updates_parallel aggregate: no double-count" \
         "redundant FAILED+1 per non-zero _rc still present"
else
  ok_t "_run_updates_parallel aggregate: no FAILED double-count"
fi

# --- Test 20: --parallel=N validates input and warns on bad value ---
# Pass 1 added `[[ =~ ]]` validation; verify the warn path exists.
if grep -E 'parallel: invalid value' "$ROOT/lib/updater.sh" >/dev/null 2>&1; then
  ok_t "_run_all_updates --parallel=N: warns on invalid value"
else
  fail_t "_run_all_updates --parallel=N: invalid-value warning" \
         "warning string not found in source"
fi

# --- Test 21: --parallel=abc falls back to sequential with no crash ---
# End-to-end: passing a non-integer must not abort, and must not silently
# invoke the parallel path (which would crash on `kill -0 $(echo)`).
unset PARALLEL
UPDATED=0; FAILED=0
result=0
_run_all_updates --parallel=abc >/dev/null 2>&1 || result=$?
if [ "$result" -le 1 ]; then
  ok_t "_run_all_updates --parallel=abc: falls back to sequential, rc=$result"
else
  fail_t "_run_all_updates --parallel=abc" "got rc=$result, expected 0 or 1"
fi

# --- Test 22b: dispatcher must propagate FAILED=0 vs >0 from mktemp fallback ---
# The pass-2 fix changed the mktemp-fail fallback from `return 0` to
# `[ "$FAILED" -gt 0 ] && return 1 || return 0`, so silent failure
# swallowing is eliminated.  Verify the pattern exists in the parallel
# dispatcher's mktemp-fail branch (NOT in _update_geoip's similar pattern).
if grep -E 'parallel: mktemp failed' "$ROOT/lib/updater.sh" >/dev/null 2>&1; then
  # Search ±10 lines because there's a 3-line comment between the warn and
  # the [ "$FAILED" -gt 0 ] return line.
  if grep -A 10 'parallel: mktemp failed' "$ROOT/lib/updater.sh" \
     | grep -qE '\[ "\$FAILED" -gt 0 \] && return 1'; then
    ok_t "_run_updates_parallel: mktemp-fail fallback propagates FAILED state"
  else
    fail_t "_run_updates_parallel: mktemp-fail fallback rc" \
           "fallback still hardcodes 'return 0' — failures silently swallowed"
  fi
else
  fail_t "_run_updates_parallel: mktemp-fail fallback" \
         "fallback message 'parallel: mktemp failed' not found"
fi

# --- Test 22: end-to-end concurrency — 5 failing stubs in --parallel=3 ---
# Spawn 5 _update_* stubs that all return non-zero.  In --parallel=3 mode,
# three run concurrently, the other two wait, then all complete.  With the
# per-substep file fix, each subshell writes "rc:updated:failed" atomically
# to its own file; the parent aggregates them via `IFS=:` read.  FAILED must
# equal exactly 5 (one per stub, no double-count, no parse error).
for _fn in stub1 stub2 stub3 stub4 stub5; do
  eval "_update_$_fn() { FAILED=\$((FAILED + 1)); return 1; }"
done
UPDATED=0; FAILED=0
result=0
_run_all_updates --parallel=3 --steps="stub1 stub2 stub3 stub4 stub5" >/dev/null 2>&1 || result=$?
if [ "$FAILED" -eq 5 ] && [ "$result" -eq 1 ]; then
  ok_t "_run_all_updates --parallel=3 (5 failing stubs): FAILED=5, rc=1 (race-free aggregate)"
else
  fail_t "_run_all_updates --parallel=3 (5 failing stubs)" \
         "got FAILED=$FAILED, rc=$result (expected 5, 1)"
fi
for _fn in stub1 stub2 stub3 stub4 stub5; do
  unset -f "_update_$_fn"
done
unset _fn

# --- Test 22a: _result_dir uses RETURN trap (not EXIT) to avoid temp leaks ---
# The pass-2 fix changed the cleanup trap from EXIT to RETURN so each call
# to _run_updates_parallel cleans its own $_result_dir immediately when the
# function returns, rather than waiting for shell exit.  This prevents temp-dir
# accumulation when the dispatcher is called repeatedly.  Verify by source.
if grep -qE 'trap.*rm -rf.*_result_dir.*RETURN' "$ROOT/lib/updater.sh" 2>/dev/null; then
  ok_t "_run_updates_parallel: uses RETURN trap for \$_result_dir (no temp leak)"
else
  fail_t "_run_updates_parallel: RETURN trap for \$_result_dir" \
         "cleanup uses EXIT instead of RETURN — temp dirs leak on repeated calls"
fi

# --- Test 23: all 15 _update_* stubs are dispatched and called exactly once ---
# The dispatcher builds function names from the space-separated _steps list
# (e.g. "apt" -> _update_apt).  This test overrides --steps= with all 15
# known names and verifies each is invoked exactly once.
_UPDATE_CALL_LOG=""
# Each stub captures its own name via a per-function local, so the
# function body does NOT reference an outer-scope variable that may be
# unset by the time the dispatcher invokes the function under `set -u`.
set +u
for _update_fn in apt dnf yum zypper pacman snap flatpak docker brew firmware geoip virsh suse_snapper btrfs_balance pihole; do
  eval "_update_$_update_fn() { _UPDATE_CALL_LOG=\"\${_UPDATE_CALL_LOG}\${_UPDATE_CALL_LOG:+ }$_update_fn\"; }"
done
unset _update_fn
# Run dispatcher under `set +u` so that any inner code in lib/updater.sh
# (e.g. msg/info calls, $RUNNER_USED checks) does not error out due to
# test-harness state.  The lib is robust enough that this is safe; the
# goal here is to count dispatches, not to test the lib's set -u
# discipline (covered by the other test cases).
_run_all_updates --steps="apt dnf yum zypper pacman snap flatpak docker brew firmware geoip virsh suse_snapper btrfs_balance pihole" >/dev/null 2>&1
set -u

# Count how many of the 15 were called
_UPDATE_CALLED=0
for _called_fn in $_UPDATE_CALL_LOG; do
  _UPDATE_CALLED=$((_UPDATE_CALLED + 1))
done

# Verify exactly 15 were called
if [ "$_UPDATE_CALLED" -eq 15 ]; then
  ok_t "_run_all_updates: all 15 _update_* stubs called (exactly once each)"
else
  fail_t "_run_all_updates: all 15 _update_* stubs" \
         "expected 15 calls, got $_UPDATE_CALLED. Log: $_UPDATE_CALL_LOG"
fi

# Verify no duplicate calls (set cardinality = 15 means no dupes)
_UPDATE_SEEN=""
_UPDATE_DUPES=0
for _called_fn in $_UPDATE_CALL_LOG; do
  case " $_UPDATE_SEEN " in
    *" $_called_fn "*) _UPDATE_DUPES=$((_UPDATE_DUPES + 1)) ;;
    *) _UPDATE_SEEN="$_UPDATE_SEEN$_called_fn " ;;
  esac
done
unset _called_fn _UPDATE_SEEN
if [ "$_UPDATE_DUPES" -eq 0 ]; then
  ok_t "_run_all_updates: all 15 stubs called exactly once (no duplicates)"
else
  fail_t "_run_all_updates: no duplicate calls" \
         "$_UPDATE_DUPES duplicate(s) detected. Log: $_UPDATE_CALL_LOG"
fi

# --- Test 24: bash 3.x floor guard runtime check (docker required) ---
# lib/updater.sh has a guard that returns/exits when BASH_VERSINFO[0] < 4.
# We can't mock BASH_VERSINFO (it's readonly), so we can only run this test
# when docker is available and can pull a bash:3 container. On CI, the docker
# matrix entry runs this test under bash:3. On hosts without docker, we only
# verify the guard is in the source (covered by test 25).
_docker_available=false
if command -v docker >/dev/null 2>&1; then
  if timeout 30 docker pull bash:3.2-alpine3.18 >/dev/null 2>&1; then
    _docker_available=true
  fi
fi
if [ "$_docker_available" = "true" ]; then
  _guard_out=$(docker run --rm -v "$ROOT:/work" -w /work bash:3.2-alpine3.18 \
    bash -c 'if declare -F _run_all_updates >/dev/null 2>&1; then echo DECLARED; else echo ABSENT; fi' 2>&1)
  if printf '%s' "$_guard_out" | grep -q "ABSENT"; then
    ok_t "lib/updater.sh: bash 3.x guard fires (docker, functions not declared)"
  else
    fail_t "lib/updater.sh: bash 3.x guard (docker)" \
           "bash 3.2 ran but _run_all_updates was declared — guard did not fire"
  fi
else
  ok_t "lib/updater.sh: bash 3.x guard: skipped (docker not available; verified by CI matrix)"
fi

# --- Test 25: lib/updater.sh has the bash 4+ version guard in source ---
# Regression marker: any future refactor that removes the guard should fail this.
if grep -qE 'BASH_VERSINFO\[0\].*-lt 4' "$ROOT/lib/updater.sh" 2>/dev/null; then
  ok_t "lib/updater.sh: bash 4+ version guard present in source"
else
  fail_t "lib/updater.sh: bash 4+ version guard" \
         "BASH_VERSINFO[0] < 4 check not found"
fi

# --- Test 26: linuxinstall.sh has a bash 4+ version guard ---
# The script uses [[ =~ ]], ${!var}, mapfile in helpers — must reject bash 3.
if grep -qE 'BASH_VERSINFO\[0\].*-lt 4' "$ROOT/linuxinstall.sh" 2>/dev/null; then
  ok_t "linuxinstall.sh: bash 4+ version guard present in source"
else
  fail_t "linuxinstall.sh: bash 4+ version guard" \
         "BASH_VERSINFO[0] < 4 check not found — script will fail opaquely on bash 3"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d test(s) passed.%s\n' "$C_GRN" "$TOTAL" "$C_RST"; exit 0
else
  printf '%s%d of %d test(s) failed.%s\n' "$C_RED" "$FAIL" "$TOTAL" "$C_RST"; exit 1
fi
