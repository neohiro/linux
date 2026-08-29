#!/usr/bin/env bash
# lib/runner.sh - shared command execution helpers.
#
# Provides two functions:
#
#   _runner_init  — call once per script. Sets defaults for STRICT_RUN,
#                   DRY_RUN, VERBOSE, FAIL_COUNT. Idempotent.
#
#   _runner_cmd   — the canonical `run` function. Named `_runner_cmd` to
#                   avoid clashing with host scripts that define their own
#                   `run()`.  Hosts can alias it:
#                     run() { _runner_cmd "$@"; }
#                   Or just source this file after their own run() is set.
#
# Features:
#   DRY_RUN=1     — print "DRY: <cmd>" without executing.
#   VERBOSE=2     — print "RUN: <cmd>" before executing.
#   FAIL_COUNT    — incremented on failure (caller's global).
#   STRICT_RUN=1  — return real exit code instead of swallowing failures.
#   _log_error()  — called on failure if declared by host script.
#
# Safe to source multiple times; guards against double-initialisation.

# Guard against double-sourcing.
[ -n "${__NEOHIRO_RUNNER_INIT:-}" ] && return 0 2>/dev/null || true
__NEOHIRO_RUNNER_INIT=1

_runner_init() {
  : "${STRICT_RUN:=0}"
  : "${DRY_RUN:=0}"
  : "${VERBOSE:=0}"
  # Initialise whichever failure counter the host uses.  We detect which one
  # by checking if it already exists (declare -p returns 0 for declared vars).
  # linuxinstall.sh uses _FAIL_COUNT; standalone runs use FAIL_COUNT.
  if declare -p _FAIL_COUNT >/dev/null 2>&1; then
    : "${_FAIL_COUNT:=0}"
  else
    : "${FAIL_COUNT:=0}"
  fi
}
_runner_init

# _runner_cmd() — canonical `run` function implementation.
# Callers can alias it:  run() { _runner_cmd "$@"; }
_runner_cmd() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '  %s\n' "DRY: $*"
    return 0
  fi

  if [ "${VERBOSE:-0}" -ge 2 ]; then
    printf '  %s\n' "RUN: $*"
  fi

  # Print command to stdout so the user sees what's running.
  # Set RUNNER_ECHO=0 before sourcing this file to suppress (restore_ssh.sh style).
  if [ "${RUNNER_ECHO:-1}" = "1" ] && declare -F msg >/dev/null 2>&1; then
    msg "$*"
  fi

  "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    if declare -F warn >/dev/null 2>&1; then
      warn "Command failed (exit $rc): $*"
    else
      printf '%s\n' "[ERROR] Command failed (exit $rc): $*" >&2
    fi
    if declare -p _FAIL_COUNT >/dev/null 2>&1; then
      _FAIL_COUNT=$((_FAIL_COUNT + 1))
    else
      FAIL_COUNT=${FAIL_COUNT:-0}
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if declare -F _log_error >/dev/null 2>&1; then
      _log_error "$rc" "$*"
    fi
    if [ "${STRICT_RUN:-0}" = "1" ]; then
      return $rc
    fi
    return 0
  fi

  return 0
}
