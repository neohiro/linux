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
# Skips unavailable tools silently unless VERBOSE is set.
#   VERBOSE=0  — quiet (only ok/warn/err messages)
#   VERBOSE=1  — include _log() per-step detail
#   VERBOSE=2  — trace every command before running (useful for dry runs)
#
# Exit: 0 = all succeeded, 1 = one or more sub-steps had errors.

# Bash 4+ is required: _update_flatpak uses `mapfile` (introduced in
# Bash 4.0).  The macOS system bash is 3.2 and will fail with a
# "bad substitution" error otherwise.  Surface this clearly rather
# than failing in an opaque way.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  local _err_tag
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    _err_tag=$(printf '\033[1;31m%s\033[0m' '[ERROR]')
  else
    _err_tag='[ERROR]'
  fi
  printf '%s %s\n' "$_err_tag" \
    "lib/updater.sh requires Bash 4.0+; found ${BASH_VERSION:-unknown}." >&2
  printf '  macOS users: install Homebrew bash:  brew install bash\n' >&2
  unset _err_tag
  return 1 2>/dev/null || exit 1
fi

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
ok()  { printf "%s %s\n" "$(_c '1;32m' '[OK]')" "$*"; }
warn(){ local m="$(_c '1;33m' '[WARN]') $*" && printf '%s\n' "$m" >&2; }
err() { local m="$(_c '1;31m' '[ERROR]') $*" && printf '%s\n' "$m" >&2; }

VERBOSE="${VERBOSE:-0}"
FAILED=0
UPDATED=0

_log()  { [ "$VERBOSE" = "1" ] && info "$*" || true; }
# _track() records success/failure for the summary. Callers should be
# wrapped in `... || true` so a single failed sub-step does not abort
# the dispatcher; the count is still surfaced in the final summary.
_track() { local rc=$? _u _f; [ $rc -ne 0 ] && _f=1 || _u=1; [ -n "${_u:-}" ] && UPDATED=$((UPDATED+1)); [ -n "${_f:-}" ] && FAILED=$((FAILED+1)); return 0; }

# `run` is provided by the shared runner. Source it if not already declared.
if ! declare -F run >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  if [ -r "$(dirname "${BASH_SOURCE[0]:-$0}")/runner.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]:-$0}")/runner.sh"
    run() { _runner_cmd "$@"; }
  else
    # Fallback for inline curl|bash runs without a lib directory.
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
fi

# _cmd() — wrapper around `run` that adds VERBOSE=2 tracing for
# commands the lib calls directly (without going through a _update_*
# sub-step).  DRY_RUN, FAIL_COUNT, _log_error, and STRICT_RUN are
# all handled inside `run`, so _cmd only needs to emit the trace line
# and delegate.
#
# Usage: _cmd sudo btrfs balance start -dusage=70 /
_cmd() {
  # `run` already handles DRY_RUN=1 by printing "DRY: <cmd>" and returning 0.
  # It also handles VERBOSE=2 internally; we skip the second trace.
  if [ "${DRY_RUN:-0}" != "1" ] && [ "${VERBOSE:-0}" -ge 2 ]; then
    printf '  %s\n' "RUN: $*"
  fi
  run "$@"
}

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
    if ! run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -qq full-upgrade; then
      err "apt upgrade failed"; _track
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove -qq 2>/dev/null || true
      run sudo apt-get -y clean -qq 2>/dev/null || true
    else
      _track
      run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove -qq
      run sudo apt-get -y clean -qq
    fi
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
  _track
  run sudo dnf autoremove -y -q
  ok "dnf"
}

_update_yum() {
  command -v yum >/dev/null 2>&1 || return 0
  msg "yum: checking for updates..."
  if ! run sudo yum update -y -q; then
    err "yum update failed"; _track; return 1
  fi
  _track
  run sudo yum autoremove -y -q
  ok "yum"
}

_update_zypper() {
  command -v zypper >/dev/null 2>&1 || return 0
  msg "zypper: refreshing + updating..."
  if ! run sudo zypper --quiet refresh; then
    err "zypper refresh failed"; _track; return 1
  fi
  if ! run sudo zypper update -y --quiet; then
    err "zypper update failed"; _track; return 1
  fi
  _track
  run sudo zypper --quiet clean
  ok "zypper"
}

_update_pacman() {
  command -v pacman >/dev/null 2>&1 || return 0
  msg "pacman: syncing + upgrading..."
  if ! run sudo pacman -Syu --noconfirm --quiet; then
    err "pacman update failed"; _track; return 1
  fi
  _track
  # Clean cache: remove all cached packages not currently installed.
  run sudo pacman -Scc --noconfirm -q
  ok "pacman"
}

# ── Snaps ──────────────────────────────────────────────────────────────────

_update_snap() {
  command -v snap >/dev/null 2>&1 || return 0
  msg "snap: refreshing all snaps..."
  # Track snap refresh outcome so the dispatcher summary is accurate.
  if _cmd sudo snap refresh; then
    _track
  else
    warn "snap refresh returned non-zero (may be intentionally held snaps)"
    FAILED=$((FAILED+1))
  fi
  # `snap list --all` requires root in some configurations; use sudo for
  # both the count and the prune to keep the output consistent.
  # Run the command once; count from it and pipe the same output to the
  # while-read loop so the prune pass doesn't call `snap list` a second time.
  # Note: UPDATED must be updated in the *current* shell, not a subshell,
  # so we count removals in a named pipe passed via process substitution.
  local _snap_stale _snap_all _snap_failed=0 _snap_removed=0
  _snap_all=$(_cmd sudo snap list --all || echo "")
  _snap_stale=$(printf '%s' "$_snap_all" | awk '/disabled/{print $1 "@" $3}' | wc -l || echo 0)
  if [ "$_snap_stale" -gt 0 ] && [ -n "${SNAP_PRUNE:-}" ]; then
    info "snap: pruning $_snap_stale disabled revision(s)..."
    while IFS= read -r _snap_rev; do
      [ -z "$_snap_rev" ] && continue
      if _cmd sudo snap remove "${_snap_rev%%@*}" --revision="${_snap_rev##*@}"; then
        _snap_removed=$((_snap_removed+1))
      else
        warn "snap: failed to remove ${_snap_rev%%@*}@${_snap_rev##*@}"
        _snap_failed=$((_snap_failed+1))
      fi
    done < <(printf '%s' "$_snap_all" | awk '/disabled/{print $1 "@" $3}')
  fi
  if [ "$_snap_removed" -gt 0 ]; then
    UPDATED=$((UPDATED+_snap_removed))
  fi
  if [ "$_snap_failed" -gt 0 ]; then
    FAILED=$((FAILED+_snap_failed))
  fi
  # ok "snap" is called by _track above on refresh success.
  # On refresh failure the warning already fired; no duplicate message needed.
}

# ── Flatpak ───────────────────────────────────────────────────────────────

_update_flatpak() {
  command -v flatpak >/dev/null 2>&1 || return 0
  msg "flatpak: updating remote repos + all installations..."
  local rc=0
  # `flatpak remote-ls --updates` exits 0 whether or not there are updates
  # available, so we count lines to decide. Use process substitution to
  # avoid SIGPIPE under set -o pipefail.
  if mapfile -t _flatpak_updates < <(flatpak remote-ls --updates 2>/dev/null); then
    if [ "${#_flatpak_updates[@]}" -gt 0 ]; then
      if ! run flatpak update -y --assumeyes; then
        err "flatpak update failed"; _track; rc=1
      else
        _track
      fi
    else
      _log "flatpak: no updates available"
    fi
  else
    _log "flatpak: remote-ls failed — skipping"
  fi
  unset _flatpak_updates
  if run flatpak uninstall --unused -y --assumeyes 2>/dev/null; then
    _log "flatpak: uninstalled unused refs"
  else
    warn "flatpak: uninstall --unused failed"
    FAILED=$((FAILED+1))
  fi
  ok "flatpak"
  return $rc
}

# ── Docker ────────────────────────────────────────────────────────────────

_update_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  msg "docker: pulling latest images..."
  local images
  images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' || true)
  if [ -z "$images" ]; then
    _log "docker: no local images to update"
    return 0
  fi
  local failed=0
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    if run docker pull "$img" >/dev/null 2>&1; then
      _log "docker: updated $img"
      UPDATED=$((UPDATED+1))
    else
      warn "docker: failed to pull $img"
      failed=$((failed+1))
    fi
  done <<< "$images"
  run docker image prune -f >/dev/null 2>&1 || true
  if [ $failed -gt 0 ]; then
    FAILED=$((FAILED+failed))
    return 1
  fi
}

# ── Homebrew ─────────────────────────────────────────────────────────────

_update_brew() {
  command -v brew >/dev/null 2>&1 || return 0
  msg "brew: updating..."
  local brew_failed=0
  if ! HOMEBREW_NO_ANALYTICS=1 run brew update 2>/dev/null; then
    warn "brew: brew update failed"; brew_failed=1
  fi
  if ! run brew upgrade 2>/dev/null; then
    warn "brew: brew upgrade failed"; brew_failed=1
  fi
  if ! run brew cleanup -s -q 2>/dev/null; then
    warn "brew: brew cleanup failed"; brew_failed=1
  fi
  if [ "$brew_failed" -eq 0 ]; then _track; ok "brew"; else FAILED=$((FAILED+1)); return 1; fi
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
    if run sudo fwupdmgr update -y --no-reboot-check 2>/dev/null; then
      _track
      ok "fwupdmgr"
    else
      warn "fwupdmgr: update failed"
      FAILED=$((FAILED+1))
      ok "fwupdmgr (partial)"
    fi
  else
    _log "fwupdmgr: no firmware updates"
  fi
}

# ── GeoIP database (MaxMind) ─────────────────────────────────────────────

_update_geoip() {
  # Update the MaxMind GeoIP database. We look for any of the common
  # GeoLite2 / legacy GeoIP.dat file locations and update the first match
  # that is older than 30 days.
  #
  # Sources (checked in order):
  #   MAXMIND_LICENSE_KEY  — official MaxMind (requires free account; 30 dl/day).
  #     Register at https://www.maxmind.com/en/accounts/current/license-key
  #     Export:  MAXMIND_LICENSE_KEY=your_key
  #   GEOIP_URL             — arbitrary mirror (any URL returning a .mmdb file).
  #     Export:  GEOIP_URL=https://your-mirror.example.com/GeoLite2-Country.mmdb
  #   (default)             — community-maintained fork (no account needed).
  local _geoip_url="" _key
  if [ -n "${MAXMIND_LICENSE_KEY:-}" ]; then
    _key=$(printf '%s' "${MAXMIND_LICENSE_KEY}" | tr -d '[:space:]')
    if [ -n "$_key" ]; then
      _geoip_url="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${_key}&suffix=tar.gz"
    fi
  fi
  if [ -z "$_geoip_url" ] && [ -n "${GEOIP_URL:-}" ]; then
    _geoip_url="$GEOIP_URL"
  fi
  if [ -z "$_geoip_url" ]; then
    _geoip_url="https://raw.githubusercontent.com/maccurry/GeoIP-country/main/GeoLite2-Country.mmdb"
  fi
  # Common locations for GeoIP Country database.
  local _geoip_db geoip_candidates=(
    "/usr/share/GeoIP/GeoLite2-Country.mmdb"
    "/usr/share/GeoIP/GeoLite2-City.mmdb"
    "/var/lib/GeoIP/GeoLite2-Country.mmdb"
    "/usr/share/GeoIP/GeoIP.dat"
    "/usr/share/GeoIP/GeoLite.dat"
  )
  for _geoip_db in "${geoip_candidates[@]}"; do
    [ -f "$_geoip_db" ] && break
  done
  if [ ! -f "$_geoip_db" ]; then
    _log "geoip: no database found — skipping"
    return 0
  fi
  # Check age: skip if the file was modified within the last 30 days.
  local _geoip_age
  _geoip_age=$(find "$_geoip_db" -mtime -30 2>/dev/null | wc -l || echo 0)
  if [ "$_geoip_age" -gt 0 ]; then
    _log "geoip: database is recent — skipping"
    return 0
  fi
  msg "geoip: updating MaxMind GeoLite2 database..."
  local _geoip_tmpdir
  _geoip_tmpdir=$(mktemp -d) || { warn "geoip: mktemp failed"; return 1; }
  trap 'rm -rf "$_geoip_tmpdir" 2>/dev/null || true' RETURN
  if [[ "$_geoip_url" == *.tar.gz ]]; then
    # MaxMind distributes .tar.gz. Download, extract, install the .mmdb.
    local _geoip_tar="$_geoip_tmpdir/geoip.tar.gz"
    if _cmd curl -fsSL "$_geoip_url" -o "$_geoip_tar" 2>/dev/null; then
      if _cmd tar -xzf "$_geoip_tar" -C "$_geoip_tmpdir" 2>/dev/null; then
        local _geoip_mmdb
        _geoip_mmdb=$(find "$_geoip_tmpdir" -name 'GeoLite2-Country.mmdb' -type f 2>/dev/null | head -1)
        if [ -n "$_geoip_mmdb" ] && [ -f "$_geoip_mmdb" ]; then
          if _cmd sudo install -m 644 "$_geoip_mmdb" "$_geoip_db"; then
            _track; ok "geoip (MaxMind, updated)"
          else
            warn "geoip: install failed"
            FAILED=$((FAILED+1))
          fi
        else
          warn "geoip: archive did not contain expected .mmdb file"
          FAILED=$((FAILED+1))
        fi
      else
        warn "geoip: tar extraction failed"
        FAILED=$((FAILED+1))
      fi
    else
      warn "geoip: download failed (check MAXMIND_LICENSE_KEY)"
      FAILED=$((FAILED+1))
    fi
  else
    # Community mirror or custom URL — single .mmdb file.
    local _geoip_tmpdb="$_geoip_tmpdir/geoip.mmdb"
    if _cmd curl -fsSL "$_geoip_url" -o "$_geoip_tmpdb" 2>/dev/null; then
      if _cmd sudo install -m 644 "$_geoip_tmpdb" "$_geoip_db"; then
        _track; ok "geoip"
      else
        warn "geoip: install failed"
        FAILED=$((FAILED+1))
      fi
    else
      warn "geoip: download failed — skipping"
      FAILED=$((FAILED+1))
    fi
  fi
  rm -rf "$_geoip_tmpdir" 2>/dev/null || true
  trap - RETURN
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
  # list of pool/net names. Use `while read` so names with embedded
  # whitespace are kept intact (a `for x in $(...)` would split them).
  local virsh_failed=0 _virsh_pools _virsh_nets
  _virsh_pools=$(run virsh pool-list --all --name 2>/dev/null || echo "")
  _virsh_nets=$(run virsh net-list --all --name 2>/dev/null || echo "")
  while IFS= read -r pool; do
    [ -z "$pool" ] && continue
    _log "virsh: refreshing pool $pool"
    if ! run sudo virsh pool-refresh "$pool" 2>/dev/null; then
      warn "virsh: pool-refresh failed for $pool"
      virsh_failed=$((virsh_failed+1))
    fi
  done <<< "$(printf '%s' "$_virsh_pools" | sed -e '/^$/d' -e '/^Name$/d')"
  while IFS= read -r net; do
    [ -z "$net" ] && continue
    _log "virsh: auto-starting network $net"
    if ! run sudo virsh net-autostart "$net" 2>/dev/null; then
      warn "virsh: net-autostart failed for $net"
      virsh_failed=$((virsh_failed+1))
    fi
  done <<< "$(printf '%s' "$_virsh_nets" | sed -e '/^$/d' -e '/^Name$/d')"
  if [ $virsh_failed -gt 0 ]; then
    FAILED=$((FAILED+virsh_failed))
    warn "virsh: $virsh_failed pool/net operation(s) failed"
    return 1
  else
    _track; ok "virsh"
  fi
}

# ── Distro-specific tooling ───────────────────────────────────────────────

_update_suse_snapper() {
  command -v snapper >/dev/null 2>&1 || return 0
  if [ "$EUID" -ne 0 ]; then
    _log "snapper: requires root — skipping"
    return 0
  fi
  msg "snapper: creating pre-update snapshot..."
  local _snap_snap _snap_id
  _snap_snap=$(_cmd sudo snapper create -t pre -p -u -c root 2>/dev/null || true)
  _snap_id=$(echo "$_snap_snap" | awk '{print $1}' || echo "")
  if [ -n "$_snap_id" ]; then
    info "snapper: snapshot $_snap_id created"
    _track
  else
    warn "snapper: could not create snapshot"
    FAILED=$((FAILED+1))
    return 1
  fi
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
  msg "btrfs: usage at ${usage}% — running usage-balanced operation..."
  if _cmd sudo btrfs balance start -dusage=70 / 2>&1; then
    _track
    ok "btrfs balance complete"
  else
    warn "btrfs balance returned non-zero — may need manual intervention"
    FAILED=$((FAILED+1))
    return 1
  fi
}

_update_pihole() {
  command -v pihole >/dev/null 2>&1 || return 0
  if [ "$EUID" -ne 0 ]; then
    _log "pihole: requires root — skipping"
    return 0
  fi
  msg "pihole: updating gravity + lists + pihole-FTL..."
  # -g updates the blocklist; -up updates the pihole-FTL binary.
  # Both are non-fatal in isolation (gravity can fail without affecting
  # pihole-FTL) so we accumulate a per-step _track outcome.
  local pihole_updated=0
  if _cmd sudo pihole -g 2>/dev/null; then
    pihole_updated=1
  else
    warn "pihole: gravity update failed"
    FAILED=$((FAILED+1))
  fi
  if _cmd sudo pihole -up 2>/dev/null; then
    pihole_updated=1
  else
    warn "pihole: pihole-FTL update failed"
    FAILED=$((FAILED+1))
  fi
  [ "$pihole_updated" -gt 0 ] && _track
  [ "$pihole_updated" -eq 0 ] && [ "$FAILED" -gt 0 ] && return 1 || return 0
}

# ── Main dispatcher ───────────────────────────────────────────────────────

# _run_all_updates([--summary=json] [--parallel=N])
#
# Flags:
#   --summary=json   — emit machine-readable JSON summary to stdout instead of
#                      human-readable text. Includes: elapsed_s, updated (int),
#                      failed (int), steps [ { name, rc, updated, failed } ].
#   --parallel=N     — run up to N sub-steps concurrently (N >= 2).
#                      Each sub-step writes its result to a temp file so the parent
#                      can aggregate UPDATED/FAILED. PARALLEL=1 or unset
#                      means sequential execution (default).
#
# Environment:
#   VERBOSE=0        — quiet (default)
#   VERBOSE=1        — include per-step _log detail
#   VERBOSE=2        — trace every command
#   DRY_RUN=1        — simulate all commands without running them
#
# Exit: 0 = all succeeded, 1 = one or more sub-steps had errors.

_run_all_updates() {
  # Parse flags.
  local _summary="text" _parallel="${PARALLEL:-1}" _p
  for _p in "$@"; do
    case "$_p" in
      --summary=json) _summary="json" ;;
      --parallel=*)   _parallel="${_p#--parallel=}";;
    esac
  done

  msg "=== Comprehensive system update ==="
  local start_sec=$SECONDS

  # Define the ordered list of sub-steps. Each entry is the function name.
  local _steps="apt dnf yum zypper pacman snap flatpak docker brew firmware geoip virsh suse_snapper btrfs_balance pihole"

  if [ "$_parallel" -ge 2 ] 2>/dev/null; then
    _run_updates_parallel "$_steps" "$_parallel" "$_summary" "$start_sec"
    return $?
  fi

  # --- Sequential dispatch ---
  local _fn
  for _fn in $_steps; do
    "_update_$_fn" || true
  done

  _print_summary "$_summary" "$((SECONDS - start_sec))"
}

# _run_updates_parallel <steps> <max_jobs> <summary_format> <start_sec>
# Runs sub-steps concurrently, collects results, prints summary.
_run_updates_parallel() {
  local _steps="$1" _max_jobs="$2" _summary="$3" _start_sec="$4"
  local _fn _pid _pids="" _result_dir

  _result_dir=$(mktemp -d) || {
    warn "parallel: mktemp failed — falling back to sequential"
    local _fn
    for _fn in $_steps; do "_update_$_fn" || true; done
    _print_summary "$_summary" "$((SECONDS - _start_sec))"
    return 0
  }
  trap 'rm -rf "$_result_dir" 2>/dev/null || true' RETURN

  local _running=0
  for _fn in $_steps; do
    # Throttle: wait if we're at max concurrency.
    while [ "$_running" -ge "$_max_jobs" ]; do
      for _p in $_pids; do
        if ! kill -0 "$_p" 2>/dev/null; then
          _pids="${_pids//$_p/}"
          _pids="${_pids# }"; _pids="${_pids# }"
          _running=$((_running - 1))
        fi
      done
      sleep 0.1
    done

    # Launch sub-step in background, write result to a file.
    (
      local _UPDATED=0 _FAILED=0 _rc=0
      "_update_$_fn"; _rc=$?
      # Aggregate counters in the result file: step_name=rc:updated:failed
      printf '%s=%d:%d:%d\n' "$_fn" "$_rc" "$UPDATED" "$FAILED" >> "$_result_dir/results"
      exit 0
    ) &
    _pids="$_pids $!"
    _running=$((_running + 1))
  done

  # Wait for remaining background jobs.
  for _p in $_pids; do wait "$_p" 2>/dev/null; done

  # Aggregate results from result files.
  local _line _name _rc _step_upd _step_fail
  while IFS='=' read -r _line; do
    [ -z "$_line" ] && continue
    _name="${_line%%=*}"
    _rc="${_line#*=}"; _rc="${_rc%%:*}"
    _step_upd="${_line#*:}"; _step_upd="${_step_upd%%:*}"
    _step_fail="${_line##*:}"
    UPDATED=$((UPDATED + _step_upd))
    FAILED=$((FAILED + _step_fail))
    # If any sub-step failed, mark the step as failed.
    [ "$_rc" -ne 0 ] 2>/dev/null && FAILED=$((FAILED + 1))
  done < "$_result_dir/results"

  _print_summary "$_summary" "$((SECONDS - _start_sec))"
}

# _print_summary <format> <elapsed>
# Prints human-readable or JSON summary based on <format>.
_print_summary() {
  local _fmt="$1" _elapsed="$2"

  if [ "$_fmt" = "json" ]; then
    # Emit JSON with bash — no jq dependency. Quotes and backslashes escaped.
    local _upd_esc="$UPDATED" _fail_esc="$FAILED"
    printf '{"elapsed_s":%d,"updated":%d,"failed":%d}\n' \
      "$_elapsed" "$UPDATED" "$FAILED"
    if [ "$FAILED" -gt 0 ]; then return 1; fi
    return 0
  fi

  # Human-readable summary.
  printf '\n'
  if [ "$UPDATED" -gt 0 ]; then
    ok "Updates complete — $UPDATED tool(s) updated in ${_elapsed}s"
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
  # Called as a script. Pass all arguments to _run_all_updates.
  set -euo pipefail
  SECONDS=0
  _run_all_updates "$@"
  exit $?
fi
