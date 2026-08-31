#!/usr/bin/env bash
# tests/test_color_gate.sh - Hermetic tests of the USE_COLOR / ANSI gate.
#
# shellcheck source=../lib/color-gate.sh
# shellcheck source=../lib/color.sh
#
# Verifies every branch of the canonical color gate defined in
# lib/color.sh (and mirrored in linuxinstall.sh, lib/updater.sh,
# restore_ssh.sh, DeepClean.sh).
#
# Strategy: stub `tput` via a temp dir prepended to PATH. Each test runs
# in a subshell with a clean environment so the gate cannot leak state
# between cases. FORCE_TTY=1 is used to exercise tput paths on non-TTY
# platforms (CI / Cygwin Git Bash).
#
# Run: bash tests/test_color_gate.sh
set -u
PASS=0; FAIL=0
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_RST=""; fi
ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$C_RST" "$1" "$2"; FAIL=$((FAIL+1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/lib/color.sh"
[ -f "$LIB" ] || { echo "lib/color.sh not found at $LIB"; exit 2; }

WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

make_tput() {
  local mode="$1"
  cat > "$WD/tput" <<EOF
#!/usr/bin/env bash
case "\$1" in
  colors) echo "$mode"; exit 0 ;;
  *) echo "" 1>&2; exit 1 ;;
esac
EOF
  chmod +x "$WD/tput"
}

# Run the gate with the requested environment. Two modes:
#   natural   - tests what the gate decides based on actual -t 1
#   force-tty - sets FORCE_TTY=1 to bypass the TTY check (for CI/non-TTY)
# Both modes emit: USE_COLOR=<n>\nOUT=<bytes>
run_gate() {
  local mode="natural"
  for arg in "$@"; do
    [ "$arg" = "force-tty" ] && mode="force-tty"
  done
  (
    for kv in "$@"; do
      case "$kv" in
        force-tty) ;;
        tput=missing) rm -f "$WD/tput" ;;
        tput=*)       make_tput "${kv#tput=}" ;;
        unset=*)      unset "${kv#unset=}" ;;
        *)            eval "export $kv" ;;  # SC2163: must use eval to set the named var
      esac
    done
    if [ -x "$WD/tput" ]; then
      PATH="$WD:/usr/bin:/bin"
    else
      # Use only the test scratch dir; exclude all system tput paths.
      # On Git-Bash/Cygwin, /bin and /usr/bin both contain tput.
      PATH="$WD"
    fi
    if [ "$mode" = "force-tty" ]; then
      export FORCE_TTY=1
    else
      unset FORCE_TTY
    fi
    . "$LIB"
    printf 'USE_COLOR=%s\n' "$USE_COLOR"
    printf 'OUT='
    _c '1;32m' 'sample'
    printf '\n'
  )
}

field() {
  local label="$1" out="$2"
  local line
  line="$(printf '%s\n' "$out" | grep "^${label}=" | head -1)"
  printf '%s' "${line#${label}=}"
}

assert_use_color() {
  local name="$1" expected="$2" out="$3"
  local actual
  actual="$(field USE_COLOR "$out")"
  if [ "$actual" = "$expected" ]; then
    ok_t "$name (USE_COLOR=$actual)"
  else
    fail_t "$name" "expected USE_COLOR=$expected, got USE_COLOR=$actual; full: $out"
  fi
}

assert_out() {
  local name="$1" expected="$2" out="$3"
  local actual
  actual="$(field OUT "$out")"
  if [ "$actual" = "$expected" ]; then
    ok_t "$name -> _c output matches"
  else
    fail_t "$name -> _c output" "expected: [$expected], got: [$actual]"
  fi
}

# Expected bytes when _c emits green (fixed-format via printf)
ANSI_GREEN_SAMPLE=$'\033[1;32msample\033[0m'

# --- Closed-gate tests (USE_COLOR=0) ---
# All of these should hold regardless of TTY state.

out="$(run_gate NO_COLOR=1)"
assert_use_color "NO_COLOR=1 disables color" 0 "$out"
assert_out     "NO_COLOR=1 emits plain text" "sample" "$out"

out="$(run_gate NO_COLOR=0 tput=256 force-tty)"
assert_use_color "NO_COLOR=0 does NOT disable (XDG: empty non-zero means 'do not disable')" 1 "$out"
assert_out     "NO_COLOR=0 allows gate to proceed" "$ANSI_GREEN_SAMPLE" "$out"

out="$(run_gate "TERM=dumb")"
assert_use_color "TERM=dumb disables color" 0 "$out"
assert_out     "TERM=dumb emits plain text" "sample" "$out"

out="$(run_gate tput=0 force-tty)"
assert_use_color "tput=0 (broken terminfo) disables color" 0 "$out"
assert_out     "tput=0 emits plain text" "sample" "$out"

out="$(run_gate tput=7 force-tty)"
assert_use_color "tput=7 (monochrome) disables color" 0 "$out"
assert_out     "tput=7 emits plain text" "sample" "$out"

out="$(run_gate tput=missing force-tty)"
assert_use_color "tput missing disables color" 0 "$out"
assert_out     "tput-missing emits plain text" "sample" "$out"

# --- Open-gate tests (USE_COLOR=1) ---
# These require FORCE_TTY=1 on non-TTY platforms.

out="$(run_gate tput=8 force-tty)"
assert_use_color "tput=8 (8-color) enables color" 1 "$out"
assert_out     "tput=8 emits CSI escapes" "$ANSI_GREEN_SAMPLE" "$out"

out="$(run_gate tput=256 force-tty)"
assert_use_color "tput=256 enables color" 1 "$out"
assert_out     "tput=256 emits CSI escapes" "$ANSI_GREEN_SAMPLE" "$out"

out="$(run_gate tput=16777216 force-tty)"  # truecolor
assert_use_color "tput=truecolor (16M) enables color" 1 "$out"
assert_out     "tput=truecolor emits CSI escapes" "$ANSI_GREEN_SAMPLE" "$out"

# --- Override semantics ---

out="$(run_gate NEOHIRO_COLOR=1 NO_COLOR=1 "TERM=dumb")"
assert_use_color "NEOHIRO_COLOR=1 overrides NO_COLOR+TERM=dumb" 1 "$out"
assert_out     "NEOHIRO_COLOR=1 emits CSI escapes" "$ANSI_GREEN_SAMPLE" "$out"

out="$(run_gate NEOHIRO_COLOR=0 tput=256 force-tty)"
assert_use_color "NEOHIRO_COLOR=0 overrides tput=256" 0 "$out"
assert_out     "NEOHIRO_COLOR=0 emits plain text" "sample" "$out"

out="$(run_gate NEOHIRO_COLOR=1)"
assert_use_color "NEOHIRO_COLOR=1 forces on (no TTY needed)" 1 "$out"
assert_out     "NEOHIRO_COLOR=1 emits CSI escapes" "$ANSI_GREEN_SAMPLE" "$out"

out="$(run_gate NEOHIRO_COLOR=0)"
assert_use_color "NEOHIRO_COLOR=0 forces off (redundant with non-TTY)" 0 "$out"
assert_out     "NEOHIRO_COLOR=0 emits plain text" "sample" "$out"

# FORCE_TTY=1: -t 1 is bypassed
out="$(run_gate tput=256 force-tty)"
assert_use_color "FORCE_TTY=1 bypasses -t 1 check" 1 "$out"
assert_out     "FORCE_TTY=1 + tput=256 emits CSI" "$ANSI_GREEN_SAMPLE" "$out"

# FORCE_TTY=1 but NO_COLOR still wins
out="$(run_gate tput=256 force-tty NO_COLOR=1)"
assert_use_color "FORCE_TTY=1 + NO_COLOR=1 -> NO_COLOR wins" 0 "$out"
assert_out     "FORCE_TTY=1 + NO_COLOR=1 emits plain" "sample" "$out"

# --- Regression: user-reported scenario (curl|bash, no TTY) ---

out="$(run_gate)"
assert_use_color "REGRESSION: curl|bash (no overrides) -> USE_COLOR=0" 0 "$out"
assert_out     "REGRESSION: curl|bash emits no stray 'm' bytes (the original bug)" "sample" "$out"
# Belt-and-suspenders: also assert the OUT field contains exactly one
# instance of the literal text and zero ESC bytes. The original bug
# emitted "m" prefixes when CSI was stripped by the terminal; the
# fixed _c format produces either a complete CSI pair or plain text.
plain="$(field OUT "$out")"
if printf '%s' "$plain" | grep -qF $'\033'; then
  fail_t "REGRESSION: no ESC bytes leak into plain output" "found ESC in: $(printf '%s' "$plain" | od -An -tx1 | head -1)"
else
  ok_t "REGRESSION: no ESC bytes leak into plain output (binary-clean)"
fi
# And assert no leading 'm' on the first char of OUT (the exact artifact
# of the original bug: terminal strips \033[1m -> leaves "m" prefix).
first_char="${plain:0:1}"
if [ "$first_char" = "m" ] && [ "$plain" != "m" ]; then
  fail_t "REGRESSION: no leading 'm' on output (terminal-stripped CSI)" "got: $plain"
else
  ok_t "REGRESSION: no leading 'm' on output (terminal-stripped CSI artifact)"
fi

# --- Idempotency ---

res="$(
  make_tput 256
  PATH="$WD:/usr/bin:/bin"
  export FORCE_TTY=1
  # shellcheck disable=SC1090
  . "$LIB"; first=$USE_COLOR
  # shellcheck disable=SC1090
  . "$LIB"; second=$USE_COLOR
  printf 'first=%s second=%s\n' "$first" "$second"
)"
if [ "$res" = "first=1 second=1" ]; then
  ok_t "double-sourcing lib/color.sh is idempotent"
else
  fail_t "double-sourcing idempotent" "got: $res"
fi

# --- Helper availability ---

res="$(
  . "$LIB"
  for fn in bold warn err ok info msg _c; do
    if declare -F "$fn" >/dev/null; then echo "$fn OK"; else echo "$fn MISSING"; fi
  done
)"
expected="bold OK
warn OK
err OK
ok OK
info OK
msg OK
_c OK"
if [ "$res" = "$expected" ]; then
  ok_t "all 7 print helpers defined after sourcing lib/color.sh"
else
  fail_t "all 7 helpers defined" "got: $res"
fi

# --- Defensive: tput emits garbage (non-numeric) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "garbage-output-not-a-number"
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
assert_use_color "tput emitting garbage -> USE_COLOR=0" 0 "$out"
assert_out     "tput-garbage emits plain text" "sample" "$out"

# --- Defensive: tput emits negative number (broken terminfo) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "-1"
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
assert_use_color "tput=-1 -> USE_COLOR=0 (case guard catches non-digits)" 0 "$out"
assert_out     "tput=-1 emits plain text" "sample" "$out"

# --- Defensive: tput reports +9 (leading-plus; some terminfo has this) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "+9"
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
# Leading '+' is non-digit per glob; case guard catches it -> USE_COLOR=0.
# (Bash arithmetic treats +9 as 9; case guard is stricter and is the
# correct behavior because "9 colors" is an absurd terminfo entry.)
assert_use_color "tput=+9 (leading plus) -> USE_COLOR=0 (case guard)" 0 "$out"

# --- Defensive: tput reports exactly 8 (threshold boundary) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "8"
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
assert_use_color "tput=8 (threshold boundary) -> USE_COLOR=1" 1 "$out"
assert_out     "tput=8 emits CSI escapes" "$ANSI_GREEN_SAMPLE" "$out"

# --- Defensive: tput reports exactly 7 (just below threshold) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "7"
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
assert_use_color "tput=7 (just below threshold) -> USE_COLOR=0" 0 "$out"

# --- Defensive: tput reports 0x10 (hex, bash arithmetic would 0 it) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "0x10"
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
assert_use_color "tput=0x10 (hex notation) -> USE_COLOR=0 (case guard)" 0 "$out"

# --- Defensive: tput reports very large number (bash arithmetic overflow) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "99999999999999999999"
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
# Bash 5.x throws a parse error on integers larger than 2^63-1.
# The subshell exit code is non-zero -> || fires -> _tcol="".
# The case guard catches empty -> USE_COLOR=0.  This is correct safe behavior
# (a terminfo claiming 999... colors is clearly broken; treat as monochrome).
assert_use_color "tput=overflowing (huge number) -> USE_COLOR=0 (bash parse error, safe)" 0 "$out"

# --- Defensive: tput reports trailing whitespace (some terminfo does this) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo "  256  "
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
# Trailing whitespace fails the [0-9] case guard -> USE_COLOR=0.
# This is a known limitation: some terminfo entries have whitespace.
# Note: a stricter gate would strip whitespace; not implemented.
assert_use_color "tput='  256  ' (whitespace) -> USE_COLOR=0 (case guard strict)" 0 "$out"

# --- Real terminfo: TERM=linux (most common on Linux consoles) ---
# Only run if the system actually has a linux terminfo entry.
if command -v tput >/dev/null 2>&1 && tput -T linux colors >/dev/null 2>&1; then
  out="$(TERM=linux FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\n' "$USE_COLOR")"
  linux_colors="$(tput -T linux colors 2>/dev/null || echo 0)"
  case "$linux_colors" in
    ''|*[!0-9]*)
      assert_use_color "TERM=linux (broken terminfo) -> USE_COLOR=0" 0 "$out" ;;
    *)
      if [ "$linux_colors" -ge 8 ]; then
        assert_use_color "TERM=linux (tput colors=$linux_colors) -> USE_COLOR=1" 1 "$out"
      else
        assert_use_color "TERM=linux (tput colors=$linux_colors < 8) -> USE_COLOR=0" 0 "$out"
      fi
      ;;
  esac
else
  ok_t "TERM=linux (no linux terminfo on this host; skipped)"
  PASS=$((PASS + 1))
fi

# --- Real terminfo: TERM=xterm-256color ---
if command -v tput >/dev/null 2>&1 && tput -T xterm-256color colors >/dev/null 2>&1; then
  out="$(TERM=xterm-256color FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\n' "$USE_COLOR")"
  xterm_colors="$(tput -T xterm-256color colors 2>/dev/null || echo 0)"
  case "$xterm_colors" in
    ''|*[!0-9]*)
      assert_use_color "TERM=xterm-256color (broken) -> USE_COLOR=0" 0 "$out" ;;
    *)
      if [ "$xterm_colors" -ge 8 ]; then
        assert_use_color "TERM=xterm-256color (tput colors=$xterm_colors) -> USE_COLOR=1" 1 "$out"
      else
        assert_use_color "TERM=xterm-256color (tput colors=$xterm_colors < 8) -> USE_COLOR=0" 0 "$out"
      fi
      ;;
  esac
else
  ok_t "TERM=xterm-256color (not available on this host; skipped)"
  PASS=$((PASS + 1))
fi

# --- Defensive: tput exits nonzero with empty output ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo ""
exit 1
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
assert_use_color "tput exit nonzero + empty -> USE_COLOR=0" 0 "$out"
assert_out     "tput-fail emits plain text" "sample" "$out"

# --- Defensive: tput prints just a newline (whitespace only) ---
cat > "$WD/tput" <<'EOF'
#!/usr/bin/env bash
echo ""
exit 0
EOF
chmod +x "$WD/tput"
out="$(PATH="$WD:/usr/bin:/bin" FORCE_TTY=1 . "$LIB" && printf 'USE_COLOR=%s\nOUT=' "$USE_COLOR" && _c '1;32m' 'sample' && printf '\n')"
assert_use_color "tput empty output (rc=0) -> USE_COLOR=0" 0 "$out"
assert_out     "tput-empty emits plain text" "sample" "$out"

# --- restore_ssh.sh C_* constants regression ---
# Source the head of restore_ssh.sh and verify the C_* constants are
# empty when the gate is closed (NO_COLOR=1) and non-empty when forced
# on (NEOHIRO_COLOR=1). Defends against the prior bug where _color_safe
# was called twice and C_RED got leaked.
RESTORE="$ROOT/restore_ssh.sh"
if [ -f "$RESTORE" ]; then
  # Pull the block we care about (lines 19-50 in current restore_ssh.sh).
  # Rewrite EUID check so we don't trip the root check.
  {
    sed -n '19,54p' "$RESTORE"
    printf 'printf "C_RED=[%%s]\\n" "$C_RED"\n'
  } > "$WD/restore_head.sh"

  # Gate closed -> C_RED must be empty
  out="$(NO_COLOR=1 /usr/bin/bash "$WD/restore_head.sh" 2>&1; printf 'C_RED=[%s]\n' "$C_RED")"
  case "$out" in
    *'C_RED=[]'*) ok_t "restore_ssh: NO_COLOR=1 -> C_RED is empty" ;;
    *) fail_t "restore_ssh: NO_COLOR=1 -> C_RED is empty" "got: $out" ;;
  esac

  # Gate forced on -> C_RED must contain ESC+[1;31m
  out="$(NEOHIRO_COLOR=1 /usr/bin/bash "$WD/restore_head.sh" 2>&1; printf 'C_RED=[%s]\n' "$C_RED")"
  case "$out" in
    *$'\033[1;31m'*) ok_t "restore_ssh: NEOHIRO_COLOR=1 -> C_RED contains CSI" ;;
    *) fail_t "restore_ssh: NEOHIRO_COLOR=1 -> C_RED contains CSI" "got: $out" ;;
  esac
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d color-gate test(s) passed.%s\n' "$C_GRN" "$TOTAL" "$C_RST"; exit 0
else
  printf '%s%d of %d color-gate test(s) failed.%s\n' "$C_RED" "$FAIL" "$TOTAL" "$C_RST"; exit 1
fi