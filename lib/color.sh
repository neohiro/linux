#!/usr/bin/env bash
# lib/color.sh — canonical color-gate and helpers for neohiro print helpers.
#
# Source from any script:  source "$(dirname "${BASH_SOURCE[0]}")/color.sh"
#
# After sourcing:
#   USE_COLOR=1    - 1 if ANSI escapes are safe to emit, 0 otherwise
#   _c <code> <text>  - print <text> wrapped in CSI <code>; on dumb terminals
#                       emits plain <text>
#   bold/warn/err/ok/info/msg  - the same print helpers used across all
#                                scripts (linuxinstall.sh, restore_ssh.sh,
#                                DeepClean.sh, OptimizeLinuxASR.sh)
#
# Exported constants: USE_COLOR
# Exported functions: _c, bold, warn, err, ok, info, msg
#
# The heavy lifting (the ANSI gate) lives in lib/color-gate.sh.

# Guard against double-sourcing. Bail out silently so a script can
# safely `source lib/color.sh` more than once.
[ -n "${__NEOHIRO_COLOR_SOURCED:-}" ] && return 0 2>/dev/null || true
__NEOHIRO_COLOR_SOURCED=1

# Source the canonical gate function. Resolves relative to this file's
# location (BASH_SOURCE[0]) so this works regardless of the caller's
# CWD or PATH. We compute the gate path in a way that doesn't depend
# on dirname being in PATH (tests may strip PATH to isolate tput).
_lib_color_self="${BASH_SOURCE[0]}"
_lib_color_dir="${_lib_color_self%/*}"
[ "$_lib_color_dir" = "$_lib_color_self" ] && _lib_color_dir="."
# shellcheck source=lib/color-gate.sh
. "$_lib_color_dir/color-gate.sh"
unset _lib_color_self _lib_color_dir

# Run the gate once and capture the result. This is the single source of
# truth for USE_COLOR in this process.
USE_COLOR=$(_apply_color_gate)

# _c <ansi-code> <text>  -- wrap text in CSI escapes iff USE_COLOR=1.
# The caller passes the FULL SGR code including the trailing m (e.g. '1;32m').
# Format uses %s for both args; the 'm' is NOT in the format string.
_c() { if [ "$USE_COLOR" = "1" ]; then printf '\033[%s%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

# Print helpers. All accept a single message string. warn/err go to stderr.
bold() { printf "%s\n" "$(_c '1m' "$*")"; }
warn() { printf "%s %s\n" "$(_c '1;33m' '[WARNING]')" "$*" >&2; }
err()  { printf "%s %s\n" "$(_c '1;31m' '[ERROR]')"   "$*" >&2; }
ok()   { printf "%s %s\n" "$(_c '1;32m' '[OK]')"      "$*"; }
info() { printf "  %s\n" "$*"; }
msg()  { echo "=> $*"; }