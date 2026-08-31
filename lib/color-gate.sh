#!/usr/bin/env bash
# lib/color-gate.sh — canonical ANSI gate. Single source of truth for
# USE_COLOR determination across all neohiro scripts.
#
# After sourcing, call _apply_color_gate to get the result:
#   source "$(dirname "${BASH_SOURCE[0]}")/color-gate.sh"
#   USE_COLOR=$(_apply_color_gate)
#
# Gate conditions (all must hold for USE_COLOR=1):
#   1. stdout is a TTY           (-t 1)         — override: FORCE_TTY=1
#   2. NO_COLOR is not set       (XDG convention, no-color.org spec)
#   3. TERM != dumb
#   4. tput colors >= 8          — proves SGR/ANSI capability
#
# Explicit overrides (skip all gates):
#   NEOHIRO_COLOR=1  — force on (caller assumes risk)
#   NEOHIRO_COLOR=0  — force off
#   FORCE_TTY=1      — skip -t 1 check (CI / non-TTY platforms)

[ -n "${__NEOHIRO_COLOR_GATE_SOURCED:-}" ] && return 0 2>/dev/null || true
__NEOHIRO_COLOR_GATE_SOURCED=1

# Returns 0 and prints 1 (color on) or 0 (color off).
_apply_color_gate() {
  # Fast-path: explicit force overrides skip all checks.
  if [ "${NEOHIRO_COLOR:-}" = "1" ]; then
    echo 1; return 0
  fi
  if [ "${NEOHIRO_COLOR:-}" = "0" ]; then
    echo 0; return 0
  fi

  # TTY check. FORCE_TTY=1 bypasses this entirely.
  if [ "${FORCE_TTY:-}" != "1" ] && [ ! -t 1 ]; then
    echo 0; return 0
  fi

  # XDG no-color.org: must be non-empty AND not "0".
  # NO_COLOR=1 disables; NO_COLOR= does not; NO_COLOR=0 does not.
  if [ -n "${NO_COLOR:-}" ] && [ "${NO_COLOR:-}" != "0" ]; then
    echo 0; return 0
  fi

  # TERM=dumb (screen capture, some tmux configs, etc.)
  if [ "${TERM:-}" = "dumb" ]; then
    echo 0; return 0
  fi

  # tput must be available and report >= 8 colors (SGR/ANSI capability).
  # Guard against broken terminfo: if tput errors or returns non-numeric
  # output, the gate closes rather than risking stray ANSI bytes.
  if ! command -v tput >/dev/null 2>&1; then
    echo 0; return 0
  fi

  local _tcol
  _tcol=$(tput colors 2>/dev/null) || _tcol=""
  case "${_tcol}" in
    ''|*[!0-9]*) echo 0; return 0 ;;
    *) [ "${_tcol}" -ge 8 ] 2>/dev/null && echo 1 || echo 0; return 0 ;;
  esac
}
