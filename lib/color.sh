#!/usr/bin/env bash
# lib/color.sh - canonical color-gate for all neohiro scripts.
#
# Source from any script:  source "$(dirname "${BASH_SOURCE[0]}")/lib/color.sh"
#
# After sourcing:
#   USE_COLOR=1    - 1 if ANSI escapes are safe to emit, 0 otherwise
#   _c <code> <text>  - print <text> wrapped in CSI <code>; on dumb terminals
#                       emits plain <text>
#   bold/warn/err/ok/info/msg  - the same print helpers used across all
#                                scripts (linuxinstall.sh, restore_ssh.sh,
#                                DeepClean.sh, OptimizeLinuxASR.sh)
#
# Gating is the union of three conditions:
#   1. stdout is a TTY           (-t 1)
#   2. NO_COLOR is unset/empty   (XDG convention)
#   3. TERM != dumb              (Tailscale SSH, screen capture, etc.)
# Any failure -> USE_COLOR=0 -> plain text only.

# Guard against double-sourcing. Bail out silently so a script can
# safely `source lib/color.sh` more than once.
[ -n "${__NEOHIRO_COLOR_SOURCED:-}" ] && return 0 2>/dev/null || true
__NEOHIRO_COLOR_SOURCED=1

USE_COLOR=1
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
  USE_COLOR=0
fi

# _c <ansi-code> <text>  -- wrap text in CSI escapes iff USE_COLOR=1.
_c() { if [ "$USE_COLOR" = "1" ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

# Print helpers. All accept a single message string. warn/err go to stderr.
bold() { printf "%s\n" "$(_c '1m' "$*")"; }
warn() { printf "%s %s\n" "$(_c '1;33m' '[WARNING]')" "$*" >&2; }
err()  { printf "%s %s\n" "$(_c '1;31m' '[ERROR]')"   "$*" >&2; }
ok()   { printf "%s %s\n" "$(_c '1;32m' '[OK]')"      "$*"; }
info() { printf "  %s\n" "$*"; }
msg()  { echo "=> $*"; }
