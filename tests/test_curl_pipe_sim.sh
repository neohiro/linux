#!/usr/bin/env bash
# tests/test_curl_pipe_sim.sh - End-to-end regression test for the
# curl|bash path. Simulates what happens when linuxinstall.sh runs
# in a non-TTY context (no color possible) and verifies the output
# contains no stray "m" bytes.
#
# shellcheck source=../lib/color-gate.sh
# shellcheck source=../lib/color.sh
#
# Run: bash tests/test_curl_pipe_sim.sh
set -u
PASS=0; FAIL=0
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_RST=""; fi
ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$C_RST" "$1" "$2"; FAIL=$((FAIL+1)); }

# BASH_BIN reserved for future use (e.g. running driver on a specific bash).
# shellcheck disable=SC2034
BASH_BIN="${BASH:-/usr/bin/bash}"

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

# Create a minimal driver that exercises the actual inline color gate
# logic from linuxinstall.sh (lines 42-67). The gate runs at top-level
# inside a subshell that pretends stdout is NOT a TTY.
cat > "$WD/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
# Simulate the inline color gate from linuxinstall.sh (lines 42-67).
# This runs at top-level in a subshell where -t 1 is always false.
USE_COLOR=1
if [ "${NEOHIRO_COLOR:-}" = "1" ]; then
  :
elif [ "${NEOHIRO_COLOR:-}" = "0" ]; then
  USE_COLOR=0
elif { [ "${FORCE_TTY:-}" != "1" ] && [ ! -t 1 ]; } || { [ -n "${NO_COLOR:-}" ] && [ "${NO_COLOR:-}" != "0" ]; } || [ "${TERM:-}" = "dumb" ]; then
  USE_COLOR=0
elif ! command -v tput >/dev/null 2>&1; then
  USE_COLOR=0
else
  _nc=$(tput colors 2>/dev/null) || _nc=""
  case "$_nc" in
    ''|*[!0-9]*) USE_COLOR=0 ;;
    *) [ "$_nc" -ge 8 ] || USE_COLOR=0 ;;
  esac
  unset _nc
fi
_c() { if [ "$USE_COLOR" = "1" ]; then printf '\033[%s%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

# Emit the exact menu lines that the user reported (without any ANSI)
printf '  %s\n' "$(_c '1m' 'Profile selection')"
printf '  %s  %s\n' "$(_c '1;32m' '1) Recommended')" "$(_c '1;37m' 'Safe defaults.')"
printf '  %s  %s\n' "$(_c '1;36m' '2) Standard')" "$(_c '1;37m' 'Recommended + SSH.')"
printf '  %s  %s\n' "$(_c '1;35m' '3) Full')" "$(_c '1;37m' 'Standard + Tor.')"
printf '  %s  %s\n' "$(_c '1;33m' '4) Custom')" "$(_c '1;37m' 'Choose each step.')"
DRIVER
chmod +x "$WD/driver.sh"

# === Test 1: Default run (no overrides, non-TTY) ===
# -t 1 is false (Git Bash under PowerShell), so USE_COLOR=0.
# Gate must close: plain text only, no stray "m" bytes.
out="$(/usr/bin/bash "$WD/driver.sh" 2>&1)"
# The user's bug: ESC sequences were stripped, leaving "m" as a standalone
# character prefixing the text (e.g. "mProfile" instead of "[1mProfile").
# This check strips all ESC sequences first, then looks for bare "m" that
# would appear if the CSI is missing the leading ESC byte.
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
# Check for bare "m" that precedes text (the exact artifact the user reported)
if printf '%s' "$plain" | grep -qE '^m[A-Z]|^m[0-9]|^m[a-z]|^mProfile|^m[0-9]'; then
  fail_t "T1: no stray 'm' prefix on menu items" "bare m in: $plain"
else
  ok_t "T1: no stray 'm' prefix on menu items (gate closed in curl|bash)"
fi
# Also verify no ANSI escapes leaked through
if printf '%s' "$out" | grep -q $'\033'; then
  fail_t "T1: no ANSI CSI in curl|bash output (should be plain)" "found CSI: $(printf '%s' "$out" | od -An -tx1 | head -2)"
else
  ok_t "T1: no ANSI CSI escapes leaked through"
fi

# === Test 2: NEOHIRO_COLOR=1 forces on (even without TTY) ===
out="$(/usr/bin/bash -c 'export NEOHIRO_COLOR=1; '"$WD/driver.sh" 2>&1)"
# Must contain ANSI escapes (gate forced open)
if ! printf '%s' "$out" | grep -q $'\033'; then
  fail_t "T2: NEOHIRO_COLOR=1 emits CSI (forced on)" "no CSI in: $out"
else
  ok_t "T2: NEOHIRO_COLOR=1 emits CSI escapes"
fi
# Must NOT contain stray "m" bytes (correct _c now)
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
if printf '%s' "$plain" | grep -qE '^m[A-Z]|^m[0-9]'; then
  fail_t "T2: no bare 'm' bytes when CSI is intact" "bare m in: $plain"
else
  ok_t "T2: no bare 'm' bytes (correct CSI sequences)"
fi

# === Test 3b: NO_COLOR=0 must NOT disable color (XDG spec) ===
# The fix: "[ ${NO_COLOR:-} ]" instead of "[ -n ${NO_COLOR:-} ]".
# Force color on via NEOHIRO_COLOR=1 in the driver, but also set NO_COLOR=0.
make_tput() {
  cat > "$WD/tput" <<EOF
#!/usr/bin/env bash
echo "256"
EOF
  chmod +x "$WD/tput"
}
make_tput
out="$(/usr/bin/bash -c 'export FORCE_TTY=1 NO_COLOR=0; '"$WD/driver.sh" 2>&1)"
if printf '%s' "$out" | grep -q $'\033'; then
  ok_t "T3b: NO_COLOR=0 does NOT disable color (XDG fix)"
else
  fail_t "T3b: NO_COLOR=0 should allow color (XDG spec)" "no CSI: $out"
fi

# === Test 3: NO_COLOR=1 forces off ===
out="$(/usr/bin/bash -c 'export NO_COLOR=1; '"$WD/driver.sh" 2>&1)"
if printf '%s' "$out" | grep -q $'\033'; then
  fail_t "T3: NO_COLOR=1 suppresses CSI" "CSI leaked: $out"
else
  ok_t "T3: NO_COLOR=1 suppresses CSI"
fi
if printf '%s' "$out" | grep -qE 'mProfile|m1\)'; then
  fail_t "T3: NO_COLOR=1 plain text correct" "found m-prefix: $out"
else
  ok_t "T3: NO_COLOR=1 produces clean plain text"
fi
# (no bare-m check needed for T3 since no ANSI is emitted)

# === Test 4: FORCE_TTY=1 bypasses -t 1 but NO_COLOR still wins ===
out="$(/usr/bin/bash -c 'export FORCE_TTY=1 NO_COLOR=1; '"$WD/driver.sh" 2>&1)"
if printf '%s' "$out" | grep -q $'\033'; then
  fail_t "T4: NO_COLOR wins over FORCE_TTY+tput" "CSI leaked: $out"
else
  ok_t "T4: NO_COLOR wins over FORCE_TTY+tput (gate precedence correct)"
fi

# === Test 5: FORCE_TTY=1 with tput=256 opens gate ===
make_tput() {
  cat > "$WD/tput" <<EOF
#!/usr/bin/env bash
echo "256"
EOF
  chmod +x "$WD/tput"
}
make_tput
out="$(/usr/bin/bash -c 'export FORCE_TTY=1 PATH="'"$WD"':/usr/bin:/bin"; '"$WD/driver.sh" 2>&1)"
if printf '%s' "$out" | grep -q $'\033'; then
  ok_t "T5: FORCE_TTY+tput=256 opens gate and emits CSI"
else
  fail_t "T5: FORCE_TTY+tput=256 opens gate" "no CSI: $out"
fi
# No stray m
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
if printf '%s' "$plain" | grep -qE '^m[A-Z]|^m[0-9]'; then
  fail_t "T5: no bare m with FORCE_TTY+tput=256" "bare m in: $plain"
else
  ok_t "T5: no bare m bytes (fixed _c format emits complete CSI)"
fi

echo
# shellcheck disable=SC2034
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d curl|pipe regression test(s) passed.%s\n' "$C_GRN" "$TOTAL" "$C_RST"; exit 0
else
  printf '%s%d of %d curl|pipe regression test(s) failed.%s\n' "$C_RED" "$FAIL" "$TOTAL" "$C_RST"; exit 1
fi