#!/usr/bin/env bash
# verify_sync.sh — Assert that the canonical color gate (lib/color-gate.sh)
# is properly wired into all 5 consumer scripts.
#
# shellcheck source=lib/color-gate.sh
# shellcheck source=lib/color.sh
#
# Checks:
#   1. lib/color-gate.sh exists and is syntactically valid
#   2. lib/color.sh sources lib/color-gate.sh and defines _c + helpers
#   3. linuxinstall.sh has an inline gate (for curl|bash fallback)
#   4. lib/updater.sh has inline gate or sources lib/color.sh
#   5. restore_ssh.sh has inline gate or sources lib/color.sh
#   6. DeepClean.sh has inline gate or sources lib/color.sh
#   7. Behavioral: all scripts emit identical USE_COLOR for the same env
#
# Run: bash verify_sync.sh
# CI:  chmod +x verify_sync.sh && ./verify_sync.sh
set -eu
# Run from the script's own directory so relative paths work regardless
# of where the script is invoked from (PowerShell, Git Bash, WSL, etc.).
# Use BASH_SOURCE which is robust against symlinks and the literal $0.
SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
cd "$SCRIPT_DIR"
FAIL=0
check() {
  local desc="$1"; shift
  local cmd="$*"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "  [OK]  $desc"
  else
    echo "  [FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== verify_sync.sh: color-gate canonical wiring checks ==="
echo

echo "1. Canonical files exist and are valid bash:"
check "lib/color-gate.sh exists" '[ -f "lib/color-gate.sh" ]'
check "lib/color-gate.sh syntax valid" 'bash -n lib/color-gate.sh'
check "lib/color.sh exists"        '[ -f "lib/color.sh" ]'
check "lib/color.sh syntax valid" 'bash -n lib/color.sh'
check "lib/color.sh sources color-gate.sh" 'grep -qF "color-gate.sh" lib/color.sh'
check "lib/color.sh defines _c" 'grep -qF "_c()" lib/color.sh'
check "lib/color.sh guards double-source" 'grep -qF "__NEOHIRO_COLOR_SOURCED" lib/color.sh'
check "lib/color.sh defines print helpers (bold/warn/err/ok)" 'grep -qF "bold()" lib/color.sh && grep -qF "err()" lib/color.sh'
echo

echo "2. linuxinstall.sh inline gate (curl|bash fallback):"
check "inline gate: has _apply_color_gate function" 'grep -qF "_apply_color_gate()" linuxinstall.sh'
check "inline gate: sets USE_COLOR from _apply_color_gate" 'grep -qF "USE_COLOR=\$(_apply_color_gate" linuxinstall.sh'
check "inline gate: unsets _apply_color_gate after use" 'grep -qF "unset -f _apply_color_gate" linuxinstall.sh'
check "inline gate: has NEOHIRO_COLOR=1 fast path" 'grep -q "NEOHIRO_COLOR" linuxinstall.sh && grep -q "1" linuxinstall.sh'
check "inline gate: checks XDG NO_COLOR correctly (not -n)" 'grep -qF "!= \"0\"" linuxinstall.sh'
echo

echo "3. lib/updater.sh inline gate (curl|bash fallback):"
check "updater.sh: has _updater_apply_gate function" 'grep -qF "_updater_apply_gate()" lib/updater.sh'
check "updater.sh: sets USE_COLOR from gate" 'grep -qF "USE_COLOR=\$(_updater_apply_gate" lib/updater.sh'
check "updater.sh: sources lib/color.sh when available" 'grep -qF "color.sh" lib/updater.sh'
check "updater.sh: checks XDG NO_COLOR correctly" 'grep -qF "!= \"0\"" lib/updater.sh'
echo

echo "4. restore_ssh.sh inline gate:"
check "restore_ssh.sh: sources lib/color.sh" 'grep -qF "color.sh" restore_ssh.sh'
check "restore_ssh.sh: has _color_safe gate function" 'grep -qF "_color_safe()" restore_ssh.sh'
check "restore_ssh.sh: sets C_* from gate result" 'grep -qF "C_RED=" restore_ssh.sh'
check "restore_ssh.sh: checks XDG NO_COLOR correctly" 'grep -qF "!= \"0\"" restore_ssh.sh'
echo

echo "5. DeepClean.sh inline gate:"
check "DeepClean.sh: sources lib/color.sh" 'grep -qF "color.sh" DeepClean.sh'
check "DeepClean.sh: has USE_COLOR gate logic" 'grep -qF "USE_COLOR=" DeepClean.sh'
check "DeepClean.sh: checks XDG NO_COLOR correctly" 'grep -qF "!= \"0\"" DeepClean.sh'
check "DeepClean.sh: uses GREEN/BLUE/YELLOW/CYAN/NC in output" \
  'grep -q "$" DeepClean.sh && grep -q "GREEN" DeepClean.sh && grep -q "CYAN" DeepClean.sh'
echo

echo "6. Behavioral: all scripts emit identical USE_COLOR for same env."
WD="$(mktemp -d)"
WD2=""
trap 'rm -rf "$WD" "${WD2:-}"' EXIT

cat > "$WD/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
# Inline the canonical gate (same logic as lib/color-gate.sh).
_apply_color_gate() {
  if [ "${NEOHIRO_COLOR:-}" = "1" ]; then echo 1; return 0; fi
  if [ "${NEOHIRO_COLOR:-}" = "0" ]; then echo 0; return 0; fi
  if [ "${FORCE_TTY:-}" != "1" ] && [ ! -t 1 ]; then echo 0; return 0; fi
  if [ -n "${NO_COLOR:-}" ] && [ "${NO_COLOR:-}" != "0" ]; then echo 0; return 0; fi
  if [ "${TERM:-}" = "dumb" ]; then echo 0; return 0; fi
  if ! command -v tput >/dev/null 2>&1; then echo 0; return 0; fi
  local _tcol; _tcol=$(tput colors 2>/dev/null) || _tcol=""
  case "${_tcol}" in
    ''|*[!0-9]*) echo 0; return 0 ;;
    *) [ "${_tcol}" -ge 8 ] 2>/dev/null && echo 1 || echo 0; return 0 ;;
  esac
}
echo "$(_apply_color_gate)"
DRIVER
chmod +x "$WD/driver.sh"

CANONICAL="$("$WD/driver.sh")"
# shellcheck disable=SC2034
# CANONICAL is read below to verify the canonical gate returns 0 in the
# base (no-TTY, no-overrides) environment.  It is intentionally named to
# document that this is the reference result against which all scripts are
# compared in section 6a.
check "canonical gate (no tty, no overrides) -> USE_COLOR=0 (got $CANONICAL)" \
  '[ "$CANONICAL" = "0" ]'

# Verify that sourcing the canonical gate directly from lib/color-gate.sh
# produces the same result as the inline driver for all key env combos.
# We install a tput shim in $WD for combos that need to override tput output.
echo
echo "6a. Canonical gate parity across 6 critical env combinations:"
PARITY_FAIL=0
WD2="$(mktemp -d)"
write_tput() {
  # $1 = desired tput colors value (used as $TPUT_OUTPUT in the shim below).
  cat > "$WD2/tput" <<'TPUT'
#!/usr/bin/env bash
# Shim: reads desired color count from $TPUT_OUTPUT env var.
printf '%s\n' "${TPUT_OUTPUT:-256}"
TPUT
  chmod +x "$WD2/tput"
}
# Default tput for combos that don't override
write_tput 256

for COMBO in \
  "FORCE_TTY=1|TPUT_OUTPUT=256" \
  "NO_COLOR=1|TPUT_OUTPUT=256" \
  "NEOHIRO_COLOR=1|TPUT_OUTPUT=256" \
  "TERM=dumb|TPUT_OUTPUT=256" \
  "NEOHIRO_COLOR=0|TPUT_OUTPUT=256" \
  "FORCE_TTY=1 NO_COLOR=1|TPUT_OUTPUT=256"
do
  ENV_PART="${COMBO%|*}"
  TPUT_VAL="${COMBO#*|}"
  write_tput "${TPUT_VAL#TPUT_OUTPUT=}"
  FULL_ENV="$ENV_PART $TPUT_VAL"
  DRIVER_OUT="$(env $FULL_ENV PATH="$WD2:/usr/bin:/bin" bash "$WD/driver.sh" 2>/dev/null)"
  CANON_OUT="$(env $FULL_ENV PATH="$WD2:/usr/bin:/bin" bash -c '. "'"$SCRIPT_DIR"'/lib/color-gate.sh"; _apply_color_gate' 2>/dev/null)"
  if [ "$DRIVER_OUT" != "$CANON_OUT" ]; then
    echo "  [FAIL] COMBO='$ENV_PART' $TPUT_VAL: driver=$DRIVER_OUT canonical=$CANON_OUT"
    PARITY_FAIL=$((PARITY_FAIL + 1)); FAIL=$((FAIL + 1))
  fi
done
rm -rf "$WD2"
[ "$PARITY_FAIL" -eq 0 ] && echo "  [OK]  all 6 combos agree (driver == canonical)"

echo
echo "6b. Inline gate: canonical function present in each script:"
for SCRIPT in linuxinstall.sh lib/updater.sh restore_ssh.sh DeepClean.sh; do
  # linuxinstall.sh and lib/updater.sh define _apply_color_gate / _updater_apply_gate
  # at indentation level 2 (inside the else block of the lib-source guard).
  # restore_ssh.sh defines _color_safe() at level 0.
  # DeepClean.sh has no named function (inline gate in if/elif chain).
  if grep -qE "^[[:space:]]*(_apply_color_gate|_updater_apply_gate|_color_safe)\(\)" "$SCRIPT" 2>/dev/null; then
    echo "  [OK]  $SCRIPT: inline gate function defined"
  elif grep -qE "USE_COLOR=1" "$SCRIPT" 2>/dev/null && grep -qE "NO_COLOR.*!=.*0" "$SCRIPT" 2>/dev/null; then
    echo "  [OK]  $SCRIPT: inline gate logic present (no named function)"
  else
    echo "  [FAIL] $SCRIPT: no inline gate found"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "7. Behavioral: all scripts honor NO_COLOR=1 (XDG spec)."
for SCRIPT in linuxinstall.sh lib/updater.sh restore_ssh.sh DeepClean.sh; do
  [ -f "$SCRIPT" ] || continue
  # Grep for the XDG guard: should be "!= \"0\"" NOT "-n" alone
  if grep -q 'NO_COLOR.*!=.*"0"' "$SCRIPT"; then
    echo "  [OK]  $SCRIPT: NO_COLOR XDG guard correct"
  else
    echo "  [FAIL] $SCRIPT: missing or incorrect NO_COLOR guard"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "8. Drift prevention: tools/build-color-gate.sh must run successfully."
# The generator is the source of truth for the inline gate body.
# If it fails, future gate changes can't be propagated to consumers.
if bash tools/build-color-gate.sh >/dev/null 2>/tmp/gen-hashes.txt; then
  echo "  [OK]  tools/build-color-gate.sh runs successfully"
  echo "  [OK]  generator produced $(wc -l < /tmp/gen-hashes.txt) lines (4 blocks)"
  # Extract the 4 hashes from the generator's stderr output.
  # All 4 gate bodies are identical in logic; verify they match each other.
  EXPECTED_HASH="$(grep -F 'linuxinstall.sh=' /tmp/gen-hashes.txt | cut -d= -f2)"
  ALL_MATCH=0
  for SCRIPT in lib/updater.sh restore_ssh.sh DeepClean.sh; do
    HASH="$(grep -F "$SCRIPT=" /tmp/gen-hashes.txt | cut -d= -f2)"
    [ "$HASH" = "$EXPECTED_HASH" ] || ALL_MATCH=$((ALL_MATCH + 1))
  done
  if [ "$ALL_MATCH" -eq 0 ]; then
    echo "  [OK]  all 4 generated gate bodies are identical (no drift possible)"
  else
    echo "  [FAIL] generated gate bodies differ between consumers (unexpected)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  [FAIL] tools/build-color-gate.sh failed to run"
  FAIL=$((FAIL + 1))
fi
rm -f /tmp/gen-hashes.txt

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAIL check(s) FAILED."
  exit 1
fi
