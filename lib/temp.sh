#!/usr/bin/env bash
# lib/temp.sh - canonical temp-file handling for all neohiro scripts.
#
# Source from any script:  source "$(dirname "${BASH_SOURCE[0]}")/lib/temp.sh"
#
# After sourcing:
#   TMP_DIR       - a private mktemp -d directory cleaned on EXIT
#   _TMP_FILES=() - tracked temp files; add via _tmpfile
#   _tmpfile      - prints a new tracked temp file path
#   _tmpfile <prefix>  - same, with a custom prefix
#
# The EXIT trap cleans TMP_DIR and every _TMP_FILES entry.
# Call _log_error from your script's failure path to write a breadcrumb
# to NEOHIRO_DEBUG_LOG. The ERR trap is intentionally NOT installed here;
# see _log_error for the rationale.
#
# SECURITY NOTE: NEOHIRO_DEBUG_LOG receives command-line arguments verbatim.
# Avoid passing secrets (passwords, tokens) through run() -- they will be
# written to this log. The log is created with mode 0600 (owner-only).

# Guard against double-sourcing.
[ -n "${__NEOHIRO_TEMP_SOURCED:-}" ] && return 0 2>/dev/null || true
__NEOHIRO_TEMP_SOURCED=1

TMP_DIR="$(mktemp -d)"
_TMP_FILES=()

# Debug log location. Override with NEOHIRO_DEBUG_LOG=path. /var/log may
# be unwritable in containers; fall back to TMP_DIR.
# The file is created with mode 0600 so command arguments (which may contain
# user-supplied values) are not readable by other users on the system.
if [ -z "${NEOHIRO_DEBUG_LOG:-}" ]; then
  if [ -w /var/log ] 2>/dev/null; then
    NEOHIRO_DEBUG_LOG="/var/log/neohiro-debug.log"
  else
    NEOHIRO_DEBUG_LOG="${TMP_DIR}/neohiro-debug.log"
  fi
fi
# Create the log with owner-only permissions before any breadcrumb is written.
install -m 0600 /dev/null "$NEOHIRO_DEBUG_LOG" 2>/dev/null || touch "$NEOHIRO_DEBUG_LOG" && chmod 0600 "$NEOHIRO_DEBUG_LOG" 2>/dev/null || true

# Public: create a tracked temp file. Returns the new path.
# Usage: f=$(_tmpfile)   or   f=$(_tmpfile myprefix)
_tmpfile() {
  local prefix="${1:-neohiro}"
  local f
  f=$(install -m 0600 /dev/null "${TMPDIR:-/tmp}/${prefix}.XXXXXX" 2>/dev/null \
      || mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  _TMP_FILES+=("$f")
  printf '%s' "$f"
}

# Internal: write a breadcrumb to the debug log.
# Usage: _log_error <rc> <command-string>
# Call this from your run() implementation on each non-zero exit. The
# $BASH_COMMAND variable is not reliable outside of a trap, so callers
# must pass the actual command text.
_log_error() {
  local rc=$1
  local cmd=${2:-?}
  {
    printf '[%s] exit=%d cmd=%s pid=%d\n' \
      "$(date -Iseconds 2>/dev/null || date)" \
      "$rc" \
      "$cmd" \
      "$$" \
      >> "$NEOHIRO_DEBUG_LOG" 2>/dev/null
  }
}

# Master trap: always clean up temp files on exit.
trap 'rm -rf "$TMP_DIR" "${_TMP_FILES[@]}" 2>/dev/null' EXIT
