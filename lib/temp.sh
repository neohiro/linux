#!/usr/bin/env bash
# lib/temp.sh - canonical temp-file handling for all neohiro scripts.
#
# Source from any script:  source "$(dirname "${BASH_SOURCE[0]}")/lib/temp.sh"
#
# After sourcing:
#   TMP_DIR       - a private mktemp -d directory cleaned on EXIT/ERR
#   _TMP_FILES=() - tracked temp files; add via _tmpfile
#   _tmpfile      - prints a new tracked temp file path
#   _tmpfile <prefix>  - same, with a custom prefix
#
# The trap cleans TMP_DIR and every _TMP_FILES entry, and also logs an
# error breadcrumb to /var/log/neohiro-debug.log if a non-zero exit code
# escapes the script. Use 'set -e' (or call _on_error) to capture.

if [ -n "${__NEOHIRO_TEMP_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
__NEOHIRO_TEMP_SOURCED=1

TMP_DIR="$(mktemp -d)"
_TMP_FILES=()

# Debug log location. Override with NEOHIRO_DEBUG_LOG=path. /var/log may
# be unwritable in containers; fall back to TMP_DIR.
if [ -z "${NEOHIRO_DEBUG_LOG:-}" ]; then
  if [ -w /var/log ] 2>/dev/null; then
    NEOHIRO_DEBUG_LOG="/var/log/neohiro-debug.log"
  else
    NEOHIRO_DEBUG_LOG="${TMP_DIR}/neohiro-debug.log"
  fi
fi

# Public: create a tracked temp file. Returns the new path.
# Usage: f=$(_tmpfile)   or   f=$(_tmpfile myprefix)
_tmpfile() {
  local prefix="${1:-neohiro}"
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  _TMP_FILES+=("$f")
  printf '%s' "$f"
}

# Internal: write a breadcrumb to the debug log.
_log_error() {
  local rc=$1
  {
    printf '[%s] exit=%d cmd=%s pid=%d\n' \
      "$(date -Iseconds 2>/dev/null || date)" \
      "$rc" \
      "${BASH_COMMAND:-?}" \
      "$$" \
      >> "$NEOHIRO_DEBUG_LOG" 2>/dev/null
  }
}

# Internal: full cleanup. Idempotent.
_clean_temp() {
  rm -rf "$TMP_DIR" "${_TMP_FILES[@]}" 2>/dev/null
}

# Master trap. Cleanup always runs. ERR trap fires only in STRICT_RUN / CI
# mode, where a failed command is a hard abort; in interactive mode the
# script's `run()` function handles failures gracefully.
if [ "${STRICT_RUN:-0}" = "1" ] || [ -n "${CI:-}" ]; then
  trap '_log_error $?; _clean_temp; exit $?' ERR
fi
trap '_clean_temp' EXIT
