#!/usr/bin/env bash
# Generate snapshot fixtures for print_welcome and print_metrics_summary.
# Run this whenever the UX output changes intentionally.
# Outputs are platform-specific: run on the target platform.
# Usage: bash tests/gen_snapshots.sh
set -u
cd "$(dirname "$0")/.." || exit 1
SRC="linuxinstall.sh"
WD=$(mktemp -d)
trap 'rm -rf "$WD" 2>/dev/null || true' EXIT

# Source lib/color.sh
. lib/color.sh
# Stub all interactive / destructive functions
msg() { :; }; info() { :; }; ok() { :; }; warn() { :; }; err() { :; }
bold() { printf '%s\n' "$*"; }

# Extract helpers
_STRICT_LINE=$(grep -n "^STRICT_RUN=" "$SRC" | head -1 | cut -d: -f1)
_RUN_END=$(grep -n "^_ssh_inspect_config() {" "$SRC" | head -1 | cut -d: -f1)
_RUN_END=$((_RUN_END - 1))
_MAINT_START=$(grep -n "^_ssh_inspect_config() {" "$SRC" | head -1 | cut -d: -f1)
_MAINT_END=$(grep -n "^maintenance_menu() {" "$SRC" | head -1 | cut -d: -f1)
_MAINT_END=$((_MAINT_END - 1))
sed -n "${_STRICT_LINE},${_RUN_END}p" "$SRC" > "$WD/helpers.sh"
sed -n "${_MAINT_START},${_MAINT_END}p" "$SRC" >> "$WD/helpers.sh"
. "$WD/helpers.sh"

# Normalize host-specific fields before committing. print_welcome embeds the
# real hostname, OS, kernel and user; committing those leaks machine identity
# and makes the snapshot non-portable. Mirrors _normalize_output() in
# tests/test_linuxinstall.sh.
normalize_snapshot() {
  awk '
    /^  Host:[[:space:]]/     { sub(/Host:[[:space:]]+.*/,       "Host:          <HOST>");     print; next }
    /^  OS:[[:space:]]/       { sub(/OS:[[:space:]]+.*/,         "OS:            <OS>");       print; next }
    /^  Kernel:[[:space:]]/   { sub(/Kernel:[[:space:]]+.*/,     "Kernel:        <KERNEL>");   print; next }
    /^  Arch:[[:space:]]/     { sub(/Arch:[[:space:]]+.*/,       "Arch:          <ARCH>");     print; next }
    /^  Run as:[[:space:]]/   { sub(/Run as:[[:space:]]+.*/,       "Run as:        <USER>");     print; next }
    /^[[:space:]]*Disk freed:/ { sub(/Disk freed:[[:space:]]+.*/, "Disk freed (approximate)  <DISK>"); print; next }
    { print }
  '
}

# Snapshot: print_welcome (non-root, REPLY_PROFILE=2)
REPLY_PROFILE=2; QUICK_MODE=0; USE_REMOTE_SSH="no"; ENV_TYPE="server"
_USER_SAVED="${USER:-}"; USER="${USER:-testuser}"
_profile_label() { echo "Standard"; }
print_welcome | normalize_snapshot > "$WD/print_welcome_snapshot.txt"
if [ -n "$_USER_SAVED" ]; then USER="$_USER_SAVED"; else unset USER; fi

# Snapshot: print_metrics_summary (non-root, METRICS_START_DISK_KB=0)
  unset METRICS 2>/dev/null || true
  declare -A METRICS
  METRICS_START_DISK_KB=0
  METRICS[pkgs_upgraded]=2; METRICS[pkgs_installed]=1
  METRICS[services_hardened]=3; METRICS[services_stopped]=1
  METRICS[sysctls_applied]=5; METRICS[fw_rules_added]=2
  METRICS[auth_keys_added]=0; METRICS[tor_services_enabled]=0
  METRICS[configs_backed_up]=4; METRICS[rollback_logged]=4
  USE_REMOTE_SSH="no"; ENV_TYPE="server"
  ROLLBACK_LOG="/tmp/rollback-test.log"
  _metrics_bar() { printf '  %-28s %s\n' "  $1" "[████████░░░░]"; }
  print_metrics_summary | normalize_snapshot > "$WD/print_metrics_summary_snapshot.txt"

# Print where the files are and diff them against current
echo "Snapshot fixtures generated in $WD"
echo ""
echo "=== print_welcome (non-root) ==="
cat "$WD/print_welcome_snapshot.txt"
echo ""
echo "=== print_metrics_summary ==="
cat "$WD/print_metrics_summary_snapshot.txt"

# Copy to tests directory
cp "$WD/print_welcome_snapshot.txt" tests/print_welcome_snapshot.txt
cp "$WD/print_metrics_summary_snapshot.txt" tests/print_metrics_summary_snapshot.txt
echo ""
echo "Copied to tests/"
# $WD is cleaned up by the EXIT trap.
