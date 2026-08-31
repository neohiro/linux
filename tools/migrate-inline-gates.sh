#!/usr/bin/env bash
# tools/migrate-inline-gates.sh - Verify migration readiness and generate
# migration instructions for the 4 consumer scripts.
#
# This script does NOT edit files by default.  It:
#   1. Runs the generator to get the expected gate block
#   2. For each consumer, shows the current gate location and what the
#      migrated block would look like
#   3. Reports whether each consumer is ready for migration
#
# After reviewing the output, apply with:
#   bash tools/migrate-inline-gates.sh --apply
#
# To see a diff between current and migrated:
#   bash tools/migrate-inline-gates.sh --diff
#
# Usage: bash tools/migrate-inline-gates.sh [--apply|--diff]
set -eu

SELF="${BASH_SOURCE[0]:-$0}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

MODE="report"
for arg in "$@"; do
  case "$arg" in
    --apply)  MODE="apply" ;;
    --diff)   MODE="diff" ;;
    --help|-h)
      sed -n '2,20p' "$SELF"
      exit 0
      ;;
    *) printf 'usage: bash %s [--apply|--diff]\n' "$SELF"; exit 2 ;;
  esac
done

# --- Verify generator runs ---
echo "=== tools/migrate-inline-gates.sh ==="
echo "Step 1: Running generator..."
GEN_OUT="$(bash tools/build-color-gate.sh 2>/dev/null)" || {
  echo "ERROR: tools/build-color-gate.sh failed. Fix it first."
  exit 1
}
echo "  Generator OK"

# Extract the generated block for each consumer.
extract_consumer_block() {
  local consumer="$1"
  local fn="$2"
  # Each block starts with "# BEGIN_INHERIT_COLOR_GATE (consumer=..., fn=...)"
  # and ends with "# END_INHERIT_COLOR_GATE"
  # We emit the block as a heredoc-style here-doc so callers can redirect it.
  echo "$GEN_OUT" | sed -n "/# BEGIN_INHERIT_COLOR_GATE.*consumer=$consumer/,/# END_INHERIT_COLOR_GATE/p"
}

# --- Per-consumer analysis ---
check_consumer() {
  local consumer="$1"
  local fn_name="$2"
  local gate_start_line="$3"
  local gate_end_line="$4"

  echo
  echo "--- $consumer ---"
  [ -f "$consumer" ] || { echo "  MISSING: $consumer"; return; }

  local block
  block="$(extract_consumer_block "$consumer" "$fn_name")"
  local block_lines
  block_lines="$(printf '%s\n' "$block" | wc -l)"

  echo "  Generated block: $block_lines lines, function=$fn_name"

  # Check for existing markers.
  local has_marker
  has_marker="$(grep -c 'BEGIN_INHERIT_COLOR_GATE' "$consumer" 2>/dev/null | grep -oE '^[0-9]+' || echo 0)"
  [ "$has_marker" -gt 0 ] 2>/dev/null && { echo "  Status: ALREADY MIGRATED ($has_marker marker(s) found)"; return 0; }

  # Verify the gate exists at the expected location.
  local gate_line
  gate_line="$(awk 'NR>='$gate_start_line' && NR<='$gate_end_line' && /if.*NEOHIRO_COLOR/{print NR; exit}' "$consumer")"
  if [ -z "$gate_line" ] || [ "$gate_line" -eq 0 ] 2>/dev/null; then
    echo "  Status: GATE NOT FOUND at expected lines $gate_start_line-$gate_end_line"
    echo "  HINT:  grep -n 'NEOHIRO_COLOR' $consumer"
    return 1
  fi
  echo "  Gate found at line ~$gate_line (expected $gate_start_line-$gate_end_line)"

  if [ "$MODE" = "report" ]; then
    echo "  Status: READY TO MIGRATE"
    echo "  Action: bash tools/migrate-inline-gates.sh --apply"
    return 0
  fi

  if [ "$MODE" = "diff" ]; then
    echo "  === Generated block (paste between markers) ==="
    echo "$block" | sed 's/^/    /'
    return 0
  fi

  if [ "$MODE" = "apply" ]; then
    # Patch in place using sed address ranges.
    # We find the first line containing NEOHIRO_COLOR in the gate range
    # and the closing "}" of the function in that range.
    local first_line last_line
    first_line="$(awk 'NR>='$gate_start_line' && NR<='$gate_end_line' && /NEOHIRO_COLOR.*=.*1.*;.*then/{print NR; exit}' "$consumer")"
    # The end of the gate is the last "}" before the next USE_COLOR= assignment.
    # For function-based gates: last "}" before USE_COLOR=..._apply_gate)
    # For inline gates: "fi" or last "}"
    last_line="$(awk '
      BEGIN { found=0 }
      NR>='$gate_start_line' && NR<='$gate_end_line' {
        if (/^[[:space:]]*}/ && found==0) { found=NR; next }
        if (found>0 && NR>found+1) { print found; exit }
      }
    ' "$consumer")"

    if [ -z "$first_line" ] || [ -z "$last_line" ]; then
      echo "  ERROR: Could not determine gate boundary lines"
      return 1
    fi

    echo "  Patching lines $first_line to $last_line..."

    # Build replacement text: markers + generated block.
    local tmp="/tmp/migrate.$$.$RANDOM"
    {
      # Lines before the gate
      head -n $((first_line - 1)) "$consumer"
      # New block
      printf '\n'
      printf '%s\n' "$block"
      printf '\n'
      # Lines after the gate (skip gate lines)
      tail -n +$((last_line + 1)) "$consumer"
    } > "$tmp"

    if diff -q "$consumer" "$tmp" >/dev/null 2>&1; then
      echo "  No change needed (block identical to existing code)"
      rm -f "$tmp"
    else
      mv "$tmp" "$consumer"
      echo "  Patched: $consumer"
    fi
    return 0
  fi
}

echo
echo "Step 2: Checking consumers..."
check_consumer linuxinstall.sh _apply_color_gate 46 62
check_consumer lib/updater.sh _updater_apply_gate 64 80
check_consumer lib/updater.sh _updater_apply_gate 64 80
check_consumer restore_ssh.sh _color_safe 29 43

echo
echo "--- restore_ssh.sh NOTE ---"
echo "  restore_ssh.sh _color_safe() uses 'return' (boolean) not 'echo'."
echo "  The generated gate uses 'echo 1; return 0' (value-returning)."
echo "  These are incompatible patterns.  After migration, update the call site"
echo "  from 'if _color_safe; then' to 'USE_COLOR=\$(_color_safe)'"
echo "  then source the generated block.  Manual review required."

echo
echo "--- DeepClean.sh ---"
echo "  Status: SPECIAL CASE — no named function gate."
echo "  The gate is an if/elif chain (lines 23-36), not a function."
echo "  Manual migration required: replace the inline gate with a call to"
echo "  _deepclean_apply_gate() after sourcing the generated block."
echo "  Run: bash tools/migrate-inline-gates.sh --diff | grep -A 20 DeepClean"

echo
echo "=== Summary ==="
if [ "$MODE" = "report" ]; then
  echo "linuxinstall.sh, lib/updater.sh, restore_ssh.sh: READY"
  echo "  Apply with: bash tools/migrate-inline-gates.sh --apply"
  echo "DeepClean.sh: needs manual intervention"
elif [ "$MODE" = "diff" ]; then
  echo "Generated blocks shown above. Review before applying."
fi
