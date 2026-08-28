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

# Guard against double-sourcing.
[ -n "${__NEOHIRO_TEMP_SOURCED:-}" ] && return 0 2>/dev/null || true
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
# Call this explicitly from `run()` on failure, or wire into ERR if needed.
# NOTE: The ERR trap is intentionally omitted. In STRICT_RUN=1 mode, the script
# handles failure tracking via run() + _FAIL_COUNT and exits at the end of
# _print_run_summary. A per-command ERR trap would abort on the FIRST failing
# sub-command rather than collecting _FAIL_COUNT and reporting at end-of-run.
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

# Master trap: always clean up temp files on exit.
trap '_clean_temp' EXIT
