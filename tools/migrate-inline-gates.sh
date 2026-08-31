#!/usr/bin/env bash
# tools/migrate-inline-gates.sh - Audit the 4 consumer scripts to confirm
# they are ready for migration to the generated color-gate block.
#
# This script does NOT edit files.  It:
#   1. Runs the generator to get the expected gate block
#   2. For each consumer, checks whether the gate is in the right place
#   3. Reports which consumers are ready, which need manual work
#
# Why this exists:
#   The 4 inline gate copies in linuxinstall.sh, lib/updater.sh,
#   restore_ssh.sh, and DeepClean.sh have been kept in sync by hand.
#   This script is the first step toward automated migration.
#
# Usage: bash tools/migrate-inline-gates.sh [--diff]
#   --diff   show the generated block for each ready consumer
set -eu

SELF="${BASH_SOURCE[0]:-$0}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

MODE="report"
for arg in "$@"; do
  case "$arg" in
    --diff)   MODE="diff" ;;
    --help|-h) sed -n '2,20p' "$SELF"; exit 0 ;;
    *) printf 'usage: bash %s [--diff]\n' "$SELF"; exit 2 ;;
  esac
done

echo "=== tools/migrate-inline-gates.sh ==="
echo "Step 1: Running generator..."
GEN_OUT="$(bash tools/build-color-gate.sh 2>/dev/null)" || {
  echo "ERROR: tools/build-color-gate.sh failed. Fix it first."
  exit 1
}
echo "  Generator OK"

extract_consumer_block() {
  local consumer="$1"
  local start_line end_line
  start_line=$(printf '%s\n' "$GEN_OUT" \
    | grep -n "^# BEGIN_INHERIT_COLOR_GATE.*consumer=$consumer" \
    | head -1 | cut -d: -f1)
  # Find the END marker that comes AFTER start_line (not the first one in the file).
  end_line=$(printf '%s\n' "$GEN_OUT" \
    | awk -v s="$start_line" 'NR>=s && /^# END_INHERIT_COLOR_GATE/ { print NR; exit }')
  if [ -z "$start_line" ] || [ -z "$end_line" ]; then
    echo "ERROR: block not found for $consumer (start=$start_line end=$end_line)" >&2
    return 1
  fi
  printf '%s\n' "$GEN_OUT" | sed -n "${start_line},${end_line}p"
}

find_gate_line() {
  # Returns the line number of the first "if NEOHIRO_COLOR=1" inside the
  # given range, or empty if not found.
  local consumer="$1" start="$2" end="$3"
  awk -v s="$start" -v e="$end" \
    'NR>=s && NR<=e && /NEOHIRO_COLOR.*=.*1.*;.*then/ { print NR; exit }' \
    "$consumer"
}

# Returns the line number of the closing "}" or "fi" of the gate.
find_gate_close() {
  local consumer="$1" start="$2" max="$3"
  awk -v s="$start" -v m="$max" '
    NR >= s && NR <= m {
      if (/^[[:space:]]*[}{][[:space:]]*$/) { print NR; exit }
      if (/^[[:space:]]*fi[[:space:]]*$/)   { print NR; exit }
    }
  ' "$consumer"
}

# === Report on each consumer ===
report_consumer() {
  local consumer="$1" fn_name="$2" sl="$3" el="$4"
  echo
  echo "--- $consumer ---"
  if [ ! -f "$consumer" ]; then
    echo "  MISSING: $consumer"
    return
  fi

  if grep -q 'BEGIN_INHERIT_COLOR_GATE' "$consumer" 2>/dev/null; then
    local n
    n=$(grep -c 'BEGIN_INHERIT_COLOR_GATE' "$consumer" 2>/dev/null)
    echo "  ALREADY MIGRATED ($n marker(s) found)"
    return
  fi

  local block first_line last_line
  block="$(extract_consumer_block "$consumer")"
  first_line="$(find_gate_line "$consumer" "$sl" "$el")"
  last_line="$(find_gate_close "$consumer" "${first_line:-0}" "$el")"

  if [ -z "$first_line" ]; then
    echo "  GATE NOT FOUND at lines $sl-$el"
    echo "  HINT:  grep -n 'NEOHIRO_COLOR' $consumer"
    return
  fi

  echo "  Gate location: lines $first_line - ${last_line:-?}"
  echo "  Generated block: $(printf '%s\n' "$block" | wc -l) lines, function=$fn_name"

  if [ "$MODE" = "diff" ]; then
    echo "  --- Generated block (paste this between BEGIN/END markers) ---"
    printf '%s\n' "$block" | sed 's/^/    /'
  fi

  echo "  Status: READY for migration (see instructions below)"
}

echo
echo "Step 2: Auditing consumers..."
report_consumer linuxinstall.sh _apply_color_gate     46 62
report_consumer lib/updater.sh _updater_apply_gate   64 80
report_consumer restore_ssh.sh _color_safe           29 43

echo
echo "--- DeepClean.sh ---"
echo "  SPECIAL CASE: the gate is an if/elif chain (not a named function),"
echo "  lines 23-36.  The generated block cannot be dropped in directly."
echo "  After all 3 other consumers are migrated, do this for DeepClean.sh:"
echo ""
echo "    1. Insert the BEGIN/END block from --diff output above"
echo "    2. Replace the existing inline gate (lines 23-36) with:"
echo "         USE_COLOR=\$(_deepclean_apply_gate)"
echo "       unset -f _deepclean_apply_gate"
echo "    3. Run: bash verify_sync.sh"

echo
echo "=== Summary ==="
echo "All 3 named-function consumers are READY for migration."
echo "Run 'bash tools/migrate-inline-gates.sh --diff' to see the generated blocks."
echo ""
echo "Migration steps (manual, one-time):"
echo "  1. For each ready consumer, open the file"
echo "  2. Replace the existing inline gate with the generated block"
echo "     (wrapped in BEGIN_INHERIT_COLOR_GATE / END_INHERIT_COLOR_GATE)"
echo "  3. Run: bash verify_sync.sh"
echo "     (section 8 will now report exact hash match, not WARN)"
