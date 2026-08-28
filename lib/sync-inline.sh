#!/usr/bin/env bash
# lib/sync-inline.sh - verify inline fallbacks in top-level scripts
# contain the same critical commands as the canonical lib files.
#
# The top-level scripts source lib/*.sh when run from a clone, but fall back
# to inline definitions when run via curl|bash. This script detects
# functional drift by extracting the inline block and checking that every
# key statement from the canonical lib appears in the inline version.
#
# Run from the repo root:  bash lib/sync-inline.sh
# CI:                   exit 1 on any missing statement.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
LIB="$(pwd)/lib"
FAIL=0

for script in linuxinstall.sh restore_ssh.sh DeepClean.sh OptimizeLinuxASR.sh; do
  [ -f "$script" ] || continue

  # --- color.sh inline block ---
  c_start=$(awk '/^  _c\(\)/{print NR; exit}' "$script")
  c_end=$(awk -v s="${c_start:-0}" 'NR>s && /^  TMP_DIR=/{print NR-1; exit}' "$script")
  if [ -n "$c_start" ] && [ -n "$c_end" ] && [ "$c_end" -gt "$c_start" ]; then
    inline=$(sed -n "${c_start},${c_end}p" "$script")
    # Canonical lib body: every non-blank, non-comment line from _c() through msg()
    canonical=$(awk '
      /^. _c\(\)/{p=1}
      p && /^msg\(\)/{p=0; exit}
      p && !/^#/ && !/^[[:space:]]*$/ {print}
    ' "$LIB/color.sh")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if ! grep -qF "$line" <<< "$inline"; then
        echo "DRIFT: $script missing: $line"
        FAIL=1
      fi
    done <<< "$canonical"
  fi

  # --- temp.sh inline block ---
  t_start=$(awk '/^  TMP_DIR="\$\(mktemp/{print NR; exit}' "$script")
  unset_line=$(awk '/^unset _NEOHIRO_LIB_DIR/{print NR; exit}' "$script")
  if [ -n "$t_start" ] && [ -n "$unset_line" ]; then
    # Inline ends at the last "}" of _tmpfile (2 lines before the outer "fi")
    t_end=$((unset_line - 2))
    inline=$(sed -n "${t_start},${t_end}p" "$script")
    # Canonical lib body: every non-blank, non-comment line from
    # TMP_DIR="$(mktemp -d)" through the end of _tmpfile.
    canonical=$(awk '
      /^.TMP_DIR="\$\(mktemp/{p=1}
      p && /^.}$/ {p=0; exit}
      p && !/^#/ && !/^[[:space:]]*$/ {print}
    ' "$LIB/temp.sh")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if ! grep -qF "$line" <<< "$inline"; then
        echo "DRIFT: $script missing: $line"
        FAIL=1
      fi
    done <<< "$canonical"
  fi
done

[ "$FAIL" -eq 0 ] && echo "INLINE: no drift detected"
exit "$FAIL"
