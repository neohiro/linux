#!/usr/bin/env bash
# lib/updater.sh - comprehensive cross-distro update engine.
#
# Can be sourced (provides _run_all_updates function) or run standalone:
#   source lib/updater.sh
#   _run_all_updates
#
#   bash lib/updater.sh          # standalone, uses lib/color.sh inline or sourced
#   sudo bash lib/updater.sh     # standalone
#
# Updates: apt/dnf/yum/zypper/pacman, snap, flatpak, docker images,
# Homebrew, fwupdmgr firmware, GeoIP database, libvirt/virsh definitions,
# distro-specific tooling (e.g. snapper on SUSE, btrfs balance).
# Skips unavailable tools silently unless VERBOSE=1 is set.
#
# Exit: 0 = all succeeded, 1 = one or more failed, 2 = nothing to update.

[ -n "${__NEOHIRO_UPDATER_SOURCED:-}" ] && return 0 2>/dev/null || true
__NEOHIRO_UPDATER_SOURCED=1

# Guard against double-sourcing the color lib.
# shellcheck disable=SC1091
if [ -r "$(dirname "${BASH_SOURCE[0]:-$0}")/color.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/color.sh"
fi
if [ -z "${USE_COLOR:-}" ]; then USE_COLOR=0; fi

# Print helpers work whether sourced or run standalone.
_c()  { if [ "$USE_COLOR" = "1" ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
msg() { echo "=> $*"; }
info(){ printf '  %s\n' "$*"; }
ok()  { printf "%s %s\n" "$(_c '1;32m' '[OK]')" "$1"; }
warn(){ local m="$(_c '1;33m' '[WARN]') $*" && printf '%s\n' "$m" >&2; }
err() { local m="$(_c '1;31m' '[ERROR]') $*" && printf '%s\n' "$m" >&2; }

VERBOSE="${VERBOSE:-0}"
FAILED=0
UPDATED=0

_log()  { [ "$VERBOSE" = "1" ] && info "$*" || true; }
# _track() records success/failure for the summary. Callers should be
# wrapped in `... || true` so a single failed sub-step does not abort
# the dispatcher; the count is still surfaced in the final summary.
_track() { local rc=$?; [ $rc -ne 0 ] && FAILED=$((FAILED+1)) || UPDATED=$((UPDATED+1)); return 0; }

# `run` is normally provided by linuxinstall.sh. When this lib is run
# standalone (sudo bash lib/updater.sh), we shim a local copy that
# prints the command and passes the original exit code through.
if ! declare -F run >/dev/null 2>&1; then
  run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
      printf '  DRY: %s\n' "$*"
      return 0
    fi
    "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
      warn "Command failed (exit $rc): $*"
    fi
    return $rc
  }
fi

# ── Package managers ─────────────────────────────────────────────────────────

_update_apt() {
  command -v apt >/dev/null 2>&1 || return 0
  msg "apt: updating package lists..."
  if ! run sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    err "apt update failed"; _track; return 1
  fi
  local count
  count=$(apt list --upgradable 2>/dev/null | grep -c '/' || echo 0)
  if [ "$count" -gt 0 ]; then
    msg "apt: upgrading $count package(s)..."
    run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -qq full-upgrade
    _track
    run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove -qq
    run sudo apt-get -y clean -qq
  else
    _log "apt: nothing to upgrade"
  fi
  ok "apt"
}

_update_dnf() {
  command -v dnf >/dev/null 2>&1 || return 0
  msg "dnf: checking for updates..."
  if ! run sudo dnf upgrade --refresh -y -q; then
    err "dnf upgrade failed"; _track; return 1
  fi
  run sudo dnf autoremove -y -q
  ok "dnf"
}

_update_yum() {
  command -v yum >/dev/null 2>&1 || return 0
  msg "yum: checking for updates..."
  if ! run sudo yum update -y -q; then
    err "yum update failed"; _track; return 1
  fi
  run sudo yum autoremove -y -q
  ok "yum"
}

_update_zypper() {
  command -v zypper >/dev/null 2>&1 || return 0
  msg "zypper: refreshing + updating..."
  run sudo zypper --quiet refresh
  if ! run sudo zypper update -y --quiet; then
    err "zypper update failed"; _track; return 1
  fi
  run sudo zypper --quiet clean
  ok "zypper"
}

_update_pacman() {
  command -v pacman >/dev/null 2>&1 || return 0
  msg "pacman: syncing + upgrading..."
  if ! run sudo pacman -Syu --noconfirm --quiet; then
    err "pacman update failed"; _track; return 1
  fi
  # Clean cache: remove all cached packages not currently installed.
  run sudo pacman -Scc --noconfirm -q
  ok "pacman"
}

# ── Snaps ──────────────────────────────────────────────────────────────────

_update_snap() {
  command -v snap >/dev/null 2>&1 || return 0
  msg "snap: refreshing all snaps..."
  if ! run sudo snap refresh; then
    warn "snap refresh returned non-zero (may be intentionally held snaps)"
  fi
  local stale;   stale=$(snap list --all 2>/dev/null | awk '/disabled/{print $1 "@" $3}' | wc -l || echo 0)
  if [ "$stale" -gt 0 ] && [ -n "${SNAP_PRUNE:-}" ]; then
    info "snap: pruning $stale disabled revision(s)..."
    snap list --all 2>/dev/null | awk '/disabled/{print $1"@"$3}' | while read -r snaprev; do
      run sudo snap remove "${snaprev%%@*}" --revision="${snaprev##*@}" 2>/dev/null || true
    done
  fi
  ok "snap"
}

# ── Flatpak ───────────────────────────────────────────────────────────────

_update_flatpak() {
  command -v flatpak >/dev/null 2>&1 || return 0
  msg "flatpak: updating remote repos + all installations..."
  if ! run flatpak remote-ls --updates 2>/dev/null | grep -q .; then
    _log "flatpak: no updates available"
  else
    run flatpak update -y --assumeyes
    _track
  fi
  run flatpak uninstall --unused -y --assumeyes 2>/dev/null || true
  ok "flatpak"
}

# ── Docker ────────────────────────────────────────────────────────────────

_update_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  msg "docker: pulling latest images..."
  local images rc=0
  images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' || true)
  if [ -z "$images" ]; then
    _log "docker: no local images to update"
    return 0
  fi
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    if docker pull "$img" >/dev/null 2>&1; then
      _log "docker: updated $img"
    else
      warn "docker: failed to pull $img"
      rc=1
    fi
  done <<< "$images"
  # Prune dangling images.
  docker image prune -f >/dev/null 2>&1 || true
  if [ $rc -eq 0 ]; then ok "docker images"; else _track; fi
}

# ── Homebrew ─────────────────────────────────────────────────────────────

_update_brew() {
  command -v brew >/dev/null 2>&1 || return 0
  msg "brew: updating..."
  HOMEBREW_NO_ANALYTICS=1 run brew update 2>/dev/null || true
  if command -v brew >/dev/null 2>&1; then
    run brew upgrade 2>/dev/null || true
    run brew cleanup -s -q 2>/dev/null || true
    ok "brew"
  fi
}

# ── Firmware (fwupdmgr / LVFS) ───────────────────────────────────────────

_update_firmware() {
  command -v fwupdmgr >/dev/null 2>&1 || return 0
  msg "fwupdmgr: refreshing metadata..."
  run sudo fwupdmgr refresh 2>/dev/null || true
  local available
  available=$(fwupdmgr get-updates 2>/dev/null | grep -c 'Firmware Update' || echo 0)
  if [ "$available" -gt 0 ]; then
    msg "fwupdmgr: $available update(s) available — installing..."
    run sudo fwupdmgr update -y --no-reboot-check 2>/dev/null || true
    ok "fwupdmgr"
  else
    _log "fwupdmgr: no firmware updates"
  fi
}

# ── GeoIP database (MaxMind) ─────────────────────────────────────────────

_update_geoip() {
  local geoip_dir="/var/lib/GeoIP"
  local geoip_url="https://git.io/geoip"
  # Common locations for GeoIP Country database.
  local geoip_db geoip_candidates=(
    "/usr/share/GeoIP/GeoLite2-Country.mmdb"
    "/usr/share/GeoIP/GeoLite2-City.mmdb"
    "/var/lib/GeoIP/GeoLite2-Country.mmdb"
    "/usr/share/GeoIP/GeoIP.dat"
    "/usr/share/GeoIP/GeoLite.dat"
  )
  for geoip_db in "${geoip_candidates[@]}"; do
    [ -f "$geoip_db" ] && break
  done
  if [ ! -f "$geoip_db" ]; then
    _log "geoip: no database found — skipping"
    return 0
  fi
  # Check age: skip if newer than 30 days.
  if [ -n "$geoip_db" ] && [ -f "$geoip_db" ]; then
    local age
    age=$(find "$geoip_db" -mtime -30 2>/dev/null | wc -l || echo 0)
    if [ "$age" -gt 0 ]; then
      _log "geoip: database is recent — skipping"
      return 0
    fi
  fi
  msg "geoip: updating MaxMind GeoLite2 database..."
  local tmp_db
  tmp_db=$(mktemp)
  if curl -fsSL "$geoip_url" -o "$tmp_db" 2>/dev/null; then
    run sudo install -m 644 "$tmp_db" "$geoip_db" && ok "geoip" || { warn "geoip: install failed"; _track; }
  else
    warn "geoip: download failed — skipping"
  fi
  rm -f "$tmp_db"
}

# ── libvirt / virsh definitions ───────────────────────────────────────────

_update_virsh() {
  command -v virsh >/dev/null 2>&1 || return 0
  if [ "$EUID" -ne 0 ]; then
    _log "virsh: requires root — skipping"
    return 0
  fi
  if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
    _log "virsh: libvirtd not running — skipping"
    return 0
  fi
  msg "virsh: updating libvirt storage pool and network definitions..."
  # virsh pool/net --name prints a "Name" header followed by one name per
  # line. Strip blank lines and the literal "Name" header to get a clean
  # list of pool/net names.
  for pool in $(virsh pool-list --all --name 2>/dev/null | sed -e '/^$/d' -e '/^Name$/d'); do
    _log "virsh: refreshing pool $pool"
    run sudo virsh pool-refresh "$pool" 2>/dev/null || true
  done
  for net in $(virsh net-list --all --name 2>/dev/null | sed -e '/^$/d' -e '/^Name$/d'); do
    _log "virsh: auto-starting network $net"
    run sudo virsh net-autostart "$net" 2>/dev/null || true
  done
  ok "virsh"
}

# ── Distro-specific tooling ───────────────────────────────────────────────

_update_suse_snapper() {
  command -v snapper >/dev/null 2>&1 || return 0
  if [ "$EUID" -ne 0 ]; then
    _log "snapper: requires root — skipping"
    return 0
  fi
  msg "snapper: creating pre-update snapshot..."
  local snap snap_id
  snap=$(sudo snapper create -t pre -p -u -c root 2>/dev/null || true)
  snap_id=$(echo "$snap" | awk '{print $1}' || echo "")
  if [ -n "$snap_id" ]; then
    info "snapper: snapshot $snap_id created"
  else
    warn "snapper: could not create snapshot"
  fi
  _log "snapper: update complete"
  ok "snapper"
}

_update_btrfs_balance() {
  if ! command -v btrfs >/dev/null 2>&1; then return 0; fi
  # Only balance if / is btrfs and usage is above 70%.
  local usage
  usage=$(df -T / 2>/dev/null | awk 'NR==2 {print $6}' | tr -d '%' || echo 0)
  if [ "$usage" -lt 70 ]; then
    _log "btrfs: usage at ${usage}% — skipping balance"
    return 0
  fi
  if [ "$EUID" -ne 0 ]; then
    _log "btrfs: requires root — skipping"
    return 0
  fi
  msg "btrfs: usage at ${usage}% — consider running 'sudo btrfs balance start -dusage=70 /'"
  ok "btrfs check"
}

_update_pihole() {
  command -v pihole >/dev/null 2>&1 || return 0
  if [ "$EUID" -ne 0 ]; then
    _log "pihole: requires root — skipping"
    return 0
  fi
  msg "pihole: updating gravity + lists + pihole-FTL..."
  run sudo pihole -g 2>/dev/null || true
  run sudo pihole -up 2>/dev/null || true
  ok "pihole"
}

# ── Main dispatcher ───────────────────────────────────────────────────────

_run_all_updates() {
  msg "=== Comprehensive system update ==="
  local start_sec=$SECONDS

  # Each sub-routine is called with `|| true` so a failure in one tool
  # (e.g. dnf not installed) does not abort the rest of the dispatcher.
  # Errors are surfaced via the FAILED counter and the final summary.
  _update_apt             || true
  _update_dnf             || true
  _update_yum             || true
  _update_zypper          || true
  _update_pacman          || true
  _update_snap            || true
  _update_flatpak         || true
  _update_docker          || true
  _update_brew            || true
  _update_firmware        || true
  _update_geoip           || true
  _update_virsh           || true
  _update_suse_snapper    || true
  _update_btrfs_balance   || true
  _update_pihole          || true

  local elapsed=$((SECONDS - start_sec))
  printf '\n'
  if [ "$UPDATED" -gt 0 ]; then
    ok "Updates complete — $UPDATED tool(s) updated in ${elapsed}s"
  fi
  if [ "$FAILED" -gt 0 ]; then
    err "$FAILED tool(s) had errors — check output above"
    return 1
  fi
  if [ "$UPDATED" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    info "Everything is up to date."
  fi
  return 0
}

# Run standalone when executed directly.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  # Sourced — caller invokes _run_all_updates explicitly.
  return 0 2>/dev/null || true
else
  # Called as a script.
  set -euo pipefail
  SECONDS=0
  _run_all_updates
  exit $?
fi
