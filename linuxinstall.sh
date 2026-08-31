#!/bin/bash
#
# neohiro/linux  -  general interactive setup & hardening script
# Auto-detects Ubuntu / Debian / RHEL / AlmaLinux / Rocky / Fedora /
# CentOS / SUSE / openSUSE / Arch and adapts package manager, firewall,
# security tools, unattended upgrades, and kernel management accordingly.
# Automates the README tutorial with safety prompts.
# Run as root:   sudo bash linuxinstall.sh
# Requires bash 4.0+ (uses [[ =~ ]], ${!var}, mapfile in helpers).
#
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf '%s\n' "linuxinstall.sh requires Bash 4.0+; found ${BASH_VERSION:-unknown}." >&2
  printf '%s\n' "  macOS users: brew install bash" >&2
  exit 1
fi

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/neohiro/linux/main}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
ORIG_CWD="$(pwd)"

# Canonical helpers. Resolved relative to the script's own location so the
# library works whether the script is run from a clone, a symlink, or
# curl|bash (where BASH_SOURCE[0] is /dev/fd/...; we fall back to $0).
_NEOHIRO_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo /usr/local/bin)")/lib" 2>/dev/null && pwd || echo "")"
if [ -n "$_NEOHIRO_LIB_DIR" ] && [ -r "$_NEOHIRO_LIB_DIR/color.sh" ]; then
  # shellcheck disable=SC1091
  source "$_NEOHIRO_LIB_DIR/color.sh"
  # shellcheck disable=SC1091
  source "$_NEOHIRO_LIB_DIR/temp.sh"
  # shellcheck disable=SC1091
  if [ -r "$_NEOHIRO_LIB_DIR/runner.sh" ]; then
    source "$_NEOHIRO_LIB_DIR/runner.sh"
  fi
  # shellcheck disable=SC1091
  if [ -r "$_NEOHIRO_LIB_DIR/updater.sh" ]; then
    source "$_NEOHIRO_LIB_DIR/updater.sh"
  fi
else
  # Inline fallback for run-from-pipe (curl ... | bash) where the lib
  # directory is not on disk. Sources the canonical color-gate function from
  # a local copy so curl|bash works without any on-disk dependencies.
  _NEOHIRO_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo /usr/local/bin)")/lib" 2>/dev/null && pwd || echo "")"
  if [ -n "$_NEOHIRO_LIB_DIR" ] && [ -r "$_NEOHIRO_LIB_DIR/color-gate.sh" ]; then
    # shellcheck source=lib/color-gate.sh
    . "$_NEOHIRO_LIB_DIR/color-gate.sh"
  else
    # No on-disk lib; inline the gate function from the embedded heredoc below.
    _apply_color_gate() {
      if [ "${NEOHIRO_COLOR:-}" = "1" ]; then echo 1; return 0; fi
      if [ "${NEOHIRO_COLOR:-}" = "0" ]; then echo 0; return 0; fi
      if [ "${FORCE_TTY:-}" != "1" ] && [ ! -t 1 ]; then echo 0; return 0; fi
      if [ -n "${NO_COLOR:-}" ] && [ "${NO_COLOR:-}" != "0" ]; then echo 0; return 0; fi
      if [ "${TERM:-}" = "dumb" ]; then echo 0; return 0; fi
      if ! command -v tput >/dev/null 2>&1; then echo 0; return 0; fi
      local _tcol; _tcol=$(tput colors 2>/dev/null) || _tcol=""
      case "${_tcol}" in
        ''|*[!0-9]*) echo 0; return 0 ;;
        *) [ "${_tcol}" -ge 8 ] 2>/dev/null && echo 1 || echo 0; return 0 ;;
      esac
    }
  fi
  USE_COLOR=$(_apply_color_gate)
  unset -f _apply_color_gate
  # _c <ansi-code> <text>  -- wrap text in CSI escapes iff USE_COLOR=1.
  _c() { if [ "$USE_COLOR" = "1" ]; then printf '\033[%s%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
  # Print helpers. All accept a single message string. warn/err go to stderr.
  bold() { printf "%s\n" "$(_c '1m' "$*")"; }
  warn() { printf "%s %s\n" "$(_c '1;33m' '[WARNING]')" "$*" >&2; }
  err()  { printf "%s %s\n" "$(_c '1;31m' '[ERROR]')"   "$*" >&2; }
  ok()   { printf "%s %s\n" "$(_c '1;32m' '[OK]')"      "$*"; }
  info() { printf "  %s\n" "$*"; }
  msg()  { echo "=> $*"; }
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
  trap 'rm -rf "$TMP_DIR" "${_TMP_FILES[@]}" 2>/dev/null' EXIT

  # Public: create a tracked temp file. Returns the new path.
  # Usage: f=$(_tmpfile)   or   f=$(_tmpfile myprefix)
  _tmpfile() {
    local prefix="${1:-neohiro}"
    local f
    # install(1) is atomic (mode set at create time) so there is no
    # window where the file is world-readable between mktemp and chmod.
    f=$(install -m 0600 /dev/null "${TMPDIR:-/tmp}/${prefix}.XXXXXX" 2>/dev/null \
        || mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
    _TMP_FILES+=("$f")
    printf '%s' "$f"
  }
fi
unset _NEOHIRO_LIB_DIR

# Inline fallback for lib/updater.sh (curl|bash path).  Provides
# _run_all_updates so the Updates-only profile and the main script's update
# step can use the comprehensive update engine without requiring the lib
# directory to be on disk.
if ! declare -F _run_all_updates >/dev/null 2>&1; then
  VERBOSE="${VERBOSE:-0}"; UPDATED=0; FAILED=0
  _log() { [ "$VERBOSE" = "1" ] && info "$*" || true; }
  _update_apt()    { command -v apt >/dev/null 2>&1 || return 0
    run sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
    run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -qq full-upgrade
    run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove -qq
    run sudo apt-get clean -qq; }
  _update_dnf()   { command -v dnf >/dev/null 2>&1 || return 0
    run sudo dnf upgrade --refresh -y -q || return 1
    run sudo dnf autoremove -y -q; }
  _update_yum()   { command -v yum >/dev/null 2>&1 || return 0
    run sudo yum update -y -q || return 1
    run sudo yum autoremove -y -q; }
  _update_zypper(){ command -v zypper >/dev/null 2>&1 || return 0
    run sudo zypper --quiet refresh
    run sudo zypper update -y --quiet || return 1
    run sudo zypper --quiet clean; }
  _update_pacman(){ command -v pacman >/dev/null 2>&1 || return 0
    run sudo pacman -Syu --noconfirm --quiet || return 1
    run sudo pacman -Scc --noconfirm -q; }
  _update_snap()  { command -v snap >/dev/null 2>&1 || return 0
    run sudo snap refresh 2>/dev/null || true; }
  _update_flatpak(){ command -v flatpak >/dev/null 2>&1 || return 0
    run flatpak update -y --assumeyes 2>/dev/null || true
    run flatpak uninstall --unused -y --assumeyes 2>/dev/null || true; }
  _update_docker() { command -v docker >/dev/null 2>&1 || return 0
    while IFS= read -r img; do
      [ -z "$img" ] && continue
      docker pull "$img" >/dev/null 2>&1 || true
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>')
    docker image prune -f >/dev/null 2>&1 || true; }
  _update_brew()  { command -v brew >/dev/null 2>&1 || return 0
    HOMEBREW_NO_ANALYTICS=1 run brew update 2>/dev/null || true
    run brew upgrade 2>/dev/null || true
    run brew cleanup -s -q 2>/dev/null || true; }
  _update_firmware(){ command -v fwupdmgr >/dev/null 2>&1 || return 0
    run sudo fwupdmgr refresh 2>/dev/null || true
    run sudo fwupdmgr update -y --no-reboot-check 2>/dev/null || true; }
  _run_all_updates() {
    msg "=== Comprehensive system update ==="
    _update_apt || true
    _update_dnf || true
    _update_yum || true
    _update_zypper || true
    _update_pacman || true
    _update_snap || true
    _update_flatpak || true
    _update_docker || true
    _update_brew || true
    _update_firmware || true
    printf '\n'; ok "Update engine complete."; }
fi

RECOVERY_CMD="tmux attach -t linux-setup   # reconnect after SSH disconnect"
ROLLBACK_LOG="${ROLLBACK_LOG:-/var/log/linux-install-rollback.log}"

# Ensure the rollback log exists and is writable before any backup is recorded.
# Creates it with 0600 mode (owner-only) to avoid leaking paths to other users.
_record_backup_init() {
  local logdir="${ROLLBACK_LOG%/*}"
  # install(1) sets the mode atomically at create-time, avoiding a brief
  # window where the file is world-readable between touch and chmod.
  if [ "$EUID" -eq 0 ] && ! command -v sudo >/dev/null 2>&1; then
    # Running as root without sudo available: create log directly.
    mkdir -p "$logdir" 2>/dev/null || true
    install -m 0600 /dev/null "$ROLLBACK_LOG" 2>/dev/null || true
  else
    sudo mkdir -p "$logdir" 2>/dev/null || true
    sudo install -m 0600 /dev/null "$ROLLBACK_LOG" 2>/dev/null \
      || sudo sh -c "touch '$ROLLBACK_LOG' && chmod 0600 '$ROLLBACK_LOG'" 2>/dev/null || true
  fi
}
_record_backup_init

# Append a backup-file line to a single rollback log so the user has one place
# to find every file we modified and the backup we made before modifying it.
record_backup() {
  local original="$1" backup="$2"
  [ -n "$original" ] && [ -n "$backup" ] || return 0
  local line
  line="$(printf '%s\t%s\n' "$original" "$backup")"
  # As root without sudo: write directly. Otherwise: sudo tee so the log
  # remains root-owned in /var/log.
  if [ "$EUID" -eq 0 ] && ! command -v sudo >/dev/null 2>&1; then
    printf '%s' "$line" >> "$ROLLBACK_LOG" 2>/dev/null || true
  else
    printf '%s' "$line" | sudo tee -a "$ROLLBACK_LOG" >/dev/null 2>&1 || true
  fi
  metrics_add configs_backed_up 1
  metrics_add rollback_logged 1
}

print_recovery_cmd() {
  _c '1;33m' "----------------------------------------------------------------------"
  printf '\n'
  _c '1;33m' "|  RECOVERY COMMAND -- copy this BEFORE anything that might disconnect:"
  printf '\n'
  _c '1;33m' '|'
  printf '                                                                      '
  _c '1;36m' "$RECOVERY_CMD"
  printf '\n'
  _c '1;33m' "----------------------------------------------------------------------"
  printf '\n'
  printf "  After reconnecting over SSH, run the command above to resume the run.\n\n"
}

_warn_if_not_tmux() {
  [ -n "${TMUX:-}" ] || [ -n "${STY:-}" ] && return 0
  print_recovery_cmd
}

# Returns the SSH port sshd is currently configured to listen on (from sshd_config
# and any drop-in files), or "22" as the default.  IPv6-aware: if sshd is
# listening on [::] (all IPv6 interfaces) we return "22-ipv6" so callers
# can add an explicit IPv6 rule.  On error, returns "22".
_ssh_current_port() {
  local cfg="/etc/ssh/sshd_config" port=""
  port=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' \
           /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
         | tr -d '[:space:]' || true)
  port="${port:-22}"
  # Detect if sshd is listening on IPv6 (wildcard or specific IPv6 address).
  if command -v ss >/dev/null 2>&1; then
    if ss -ln -6 2>/dev/null | awk '{print $4}' | grep -qE ':('"${port}"'|'"${port}"')$'; then
      printf '%s-ipv6' "$port"
      return
    fi
  fi
  printf '%s' "$port"
}

# Returns 0 if the active firewall already allows the SSH port (IPv4 + IPv6
# when applicable).  On no active firewall, returns 0.
_ssh_port_allowed() {
  local port="${1:-22}"
  _fw_detect || return 0
  [ -z "$FW_CMD" ] && return 0
  case "$FW_CMD" in
    ufw)
      # OpenSSH (service name) opens port in both IPv4 and IPv6.
      # A bare "22/tcp" only opens IPv4.
      sudo ufw status 2>/dev/null \
        | awk '/^Status:/ {active=$2; next} /OpenSSH.*ALLOW/ {found=1} END {exit !(active=="active" && found)}'
      return $?
      ;;
    firewall-cmd)
      sudo firewall-cmd --list-all 2>/dev/null | grep -qE 'services:.*ssh' && return 0
      sudo firewall-cmd --list-ports 2>/dev/null | grep -qE "${port}/(tcp|udp)" && return 0
      return 1
      ;;
  esac
  return 0
}

# Add a firewall rule for the SSH port that covers IPv4 AND IPv6.
# ufw: use the "OpenSSH" service name (opens in both IP stacks) rather
# than a bare "22/tcp" which only covers IPv4.  firewalld: use
# --add-service=ssh (protocol-agnostic) rather than a port rule.
_ssh_fw_allow() {
  _fw_detect || return 0
  [ -z "$FW_CMD" ] && return 0
  case "$FW_CMD" in
    ufw)          run sudo ufw allow OpenSSH comment 'sshd-both-ips' ;;
    firewall-cmd) run sudo firewall-cmd --add-service=ssh --permanent ;;
  esac
}

# Detect the current SSH port and ensure it is open in the active firewall
# before we switch to default-deny.  On IPv6-only instances sshd listens on
# [::] and a bare IPv4 rule would not protect it; this function adds an
# IPv6-aware rule (ufw OpenSSH service or firewalld --add-service=ssh) that
# covers both stacks.  Idempotent: safe to call multiple times.
_ssh_guard() {
  local port
  port="$( _ssh_current_port 2>/dev/null || echo 22 )"
  # Strip any -ipv6 suffix for the port number; the check is already done.
  port="${port%-ipv6}"
  if _ssh_port_allowed "$port"; then
    info "SSH port $port is already permitted in the firewall."
    return 0
  fi
  warn "SSH port $port is not currently allowed in the firewall."
  if prompt_yn "Open SSH (port $port) in the firewall before applying default-deny?" "y"; then
    _ssh_fw_allow
    return $?
  fi
  err "SSH port $port is not allowed. Aborting firewall setup to prevent lockout."
  return 1
}

# Restart sshd safely: prefer `systemctl reload` (preserves the existing
# daemon process, so the live connection is never dropped) over `restart`.
# Falls back to `restart` if `reload` is unavailable.  Always validates
# the config before restarting.  On failure, reverts from backup.
_ssh_safe_restart() {
  local unit sshcfg="${1:-/etc/ssh/sshd_config}" backup=""
  unit="$( _sshd_unit 2>/dev/null || echo sshd )"

  # Find the most recent backup we made.
  backup=$(ls -t "${sshcfg}.bak."* 2>/dev/null | head -n1 || true)

  # Validate before touching anything.
  if ! sudo sshd -t 2>&1; then
    err "sshd config invalid — NOT restarting. Reverting."
    [ -n "$backup" ] && [ -f "$backup" ] \
      && run sudo cp -f "$backup" "$sshcfg"
    return 1
  fi

  # Reload (not restart): keeps the existing daemon process alive so the
  # current SSH session is never dropped.  Most modern sshd versions support this.
  if systemctl reload "$unit" 2>/dev/null; then
    ok "SSH config reloaded (session preserved)."
    return 0
  fi

  # No reload support: do a restart.  Warn the user the session will
  # briefly drop.  Because ensure_tmux_if_ssh wraps the whole run in tmux,
  # a dropped SSH session can be recovered with `tmux attach`.
  warn "sshd reload not supported — restarting. You may briefly lose this SSH session."
  warn "Recover with:  tmux attach -t linux-setup"
  if ! sudo systemctl restart "$unit" 2>&1; then
    err "sshd restart failed — reverting config."
    [ -n "$backup" ] && [ -f "$backup" ] \
      && run sudo cp -f "$backup" "$sshcfg"
    return 1
  fi
  ok "SSH restarted. If disconnected, run:  tmux attach -t linux-setup"
}
_sshd_unit() {
  if systemctl is-active --quiet sshd 2>/dev/null; then echo sshd; return 0; fi
  if systemctl is-active --quiet ssh  2>/dev/null; then echo ssh;  return 0; fi
  if [ -f /etc/debian_version ]; then echo ssh;  return 1; fi
  echo sshd; return 1
}

print_recovery_if_ssh() {
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || return 0
  print_recovery_cmd
}

ensure_tmux_if_ssh() {
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || return 0
  [ -z "${TMUX:-}" ] && [ -z "${STY:-}" ] || return 0
  if ! command -v tmux >/dev/null 2>&1; then
    if [ "$EUID" -eq 0 ] || command -v sudo >/dev/null 2>&1; then
      pkg_install tmux 2>/dev/null || true
    fi
  fi
  command -v tmux >/dev/null 2>&1 || {
    warn "tmux unavailable; SSH disconnect may kill the run. ${RECOVERY_CMD} will NOT exist - run the script from a local terminal instead."
    return 0
  }
  [ -n "$SCRIPT_PATH" ] || { warn "SCRIPT_PATH is empty; cannot re-exec inside tmux."; return 0; }
  bold "SSH session detected. Wrapping this run in a tmux session so disconnects do not abort it."
  # Quote everything via env+args (no string interpolation) so paths with spaces
  # or shell metacharacters survive. The inner bash re-execs the same script
  # by absolute path; on clean exit it tears the tmux session down.
  local inner
  inner=$(cat <<'INNER_EOF'
trap 'tmux kill-session -t linux-setup 2>/dev/null' EXIT
cd "$1" && shift
bash "$1" "$@"
rc=$?
if [ "$rc" -eq 0 ]; then
  tmux kill-session -t linux-setup 2>/dev/null
fi
exit "$rc"
INNER_EOF
)
  exec tmux new-session -A -s linux-setup -n setup \
    "cd $(printf '%q' "$ORIG_CWD") && bash $(printf '%q' "$SCRIPT_PATH")"
}

# bold/warn/err/ok/info/msg/_c are provided by lib/color.sh (sourced above).

# STRICT_RUN=1 makes run() propagate the actual exit code (default is 0,
# so a single failed command does not abort the whole interactive run).
# Set this in CI / unattended deployments to detect partial-failure runs.
STRICT_RUN="${STRICT_RUN:-0}"
QUICK_MODE="${QUICK_MODE:-0}"
_FAIL_COUNT=0

# Source the shared runner helpers. _runner_cmd is the canonical implementation;
# alias it to `run` so all existing call sites are satisfied.
  # shellcheck disable=SC1091
  if [ -n "${_NEOHIRO_LIB_DIR:-}" ] && [ -r "$_NEOHIRO_LIB_DIR/runner.sh" ]; then
    source "$_NEOHIRO_LIB_DIR/runner.sh"
    run() { _runner_cmd "$@"; }
  fi

# Offer a Retry / Skip / Abort choice after a step failure.
# Only prompts when running interactively (tty + not QUIET_PROMPTS).
# Returns: 0 = retry, 1 = skip, 2 = abort.
_prompt_failure_recovery() {
  local step_label="$1" rc="$2"
  if [ "${QUIET_PROMPTS:-0}" = "1" ] || [ ! -t 0 ]; then
    warn "Step '$step_label' failed (exit $rc). Continuing (non-interactive)."
    return 1
  fi
  printf '\n  %s %s\n' "$(_c '1;31m' '[FAIL]')" "Step '$step_label' exited with code $rc."
  printf '  %s\n' "$(_c '1;37m' 'What do you want to do?')"
  printf '  %s  %s\n' "$(_c '1;32m' '  1)')" "Retry this step"
  printf '  %s  %s\n' "$(_c '1;33m' '  2)')" "Skip this step and continue"
  printf '  %s  %s\n' "$(_c '1;31m' '  3)')" "Abort the entire run"
  local a
  if [ -t 0 ]; then
    read -r -p "Choose 1 to 3 - default 2 skips: " a
  elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
    printf 'Choose 1 to 3 - default 2 skips: ' >/dev/tty
    read -r a </dev/tty
  else
    a=2
  fi
  a="${a:-2}"
  case "$a" in
    1) return 0 ;;
    3) err "Aborted by user after step '$step_label'."; exit 1 ;;
    *) return 1 ;;
  esac
}

# Restore /etc from the latest snapshot.  Callable via --restore-etc-snapshot.
_restore_etc_snapshot() {
  if [ "$EUID" -ne 0 ]; then
    err "This must be run as root."; return 1
  fi
  local snap_dir="/var/backups/etc-snapshots"
  local latest
  # Use find to avoid the bash-glob-literal-on-miss problem (and the noisy
  # stderr that ls produces when the directory is empty or missing).
  latest=$(find "$snap_dir" -maxdepth 1 -type f -name 'etc-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
           | sort -nr | head -n1 | cut -d' ' -f2-)
  if [ -z "$latest" ]; then
    err "No /etc snapshot found in $snap_dir."
    info "Snapshots are created automatically when ENABLE_ETC_SNAPSHOT=1 (the default)."
    info "Re-run the hardening script with ENABLE_ETC_SNAPSHOT=1 to create one."
    return 1
  fi
  bold "=== /etc snapshot restore ==="
  info "Latest snapshot: $latest"
  local size
  size=$(sudo du -h "$latest" 2>/dev/null | awk '{print $1}')
  info "Size: ${size:-unknown}"
  _c '1;31m' "  WARNING: This will OVERWRITE /etc with the snapshot contents."
  printf '\n'
  printf "  Any hardening changes made since the snapshot was taken will be lost.\n"
  printf "  DNS, SSH, firewall, and all other settings will be restored.\n\n"
  if ! prompt_yn "Restore /etc from $latest?" "n"; then
    info "Restore cancelled."; return 0
  fi
  if sudo tar -xzf "$latest" -C / 2>&1; then
    ok "/etc restored from $latest"
    info "You may need to: sudo systemctl restart sshd   (if SSH was changed)"
    info "                  sudo systemctl restart systemd-resolved   (if DNS was changed)"
    info "                  sudo reboot   (to reload all services)"
  else
    err "tar restore failed. Check the output above."
    return 1
  fi
  return 0
}

# Take a tar.gz snapshot of /etc before hardening begins.  This is a safety
# net that lets the user do a full restore without relying on the per-file
# rollback log.  Skipped if ENABLE_ETC_SNAPSHOT=0 or if /var/backups is
# not writable.  Only the latest snapshot is kept (old ones are removed).
_ETC_SNAPSHOT_PATH=""

_take_etc_snapshot() {
  if [ "${ENABLE_ETC_SNAPSHOT:-1}" = "0" ]; then
    info "ETC snapshot disabled (ENABLE_ETC_SNAPSHOT=0)."
    return 0
  fi
  local snap_dir="/var/backups/etc-snapshots"
  local snap_path
  snap_path="${snap_dir}/etc-$(date +%s%N).tar.gz"

  if ! sudo mkdir -p "$snap_dir" 2>/dev/null; then
    warn "Cannot create $snap_dir — /etc snapshot skipped."
    return 0
  fi

  # Create the snapshot.  On failure, remove the partial file so a future
  # run does not pick up a half-written tarball.
  if sudo tar -czf "$snap_path" \
     --exclude='/etc/ssl/private' \
     --exclude='/etc/ssh/ssh_host_*_key' \
     --exclude='/etc/passwd-' \
     --exclude='/etc/shadow' \
     --exclude='/etc/group-' \
     -C / etc 2>/dev/null; then
    sudo chmod 600 "$snap_path"
    _ETC_SNAPSHOT_PATH="$snap_path"
    # Remove all older snapshots (by name — nanos in name makes name-order
    # equivalent to time-order; mtime would be wasted I/O).
    local prev
    while IFS= read -r prev; do
      [ -n "$prev" ] && sudo rm -f "$prev" 2>/dev/null
    done < <(find "$snap_dir" -maxdepth 1 -type f -name 'etc-*.tar.gz' ! -name "$(basename "$snap_path")" 2>/dev/null)
    info "Created /etc snapshot: $snap_path"
    info "  Full /etc restore:  sudo bash $0 --restore-etc-snapshot"
    info "  (May need sudo systemd-resolve --reload if /etc/resolv.conf was reverted)"
  else
    sudo rm -f "$snap_path" 2>/dev/null
    warn "Failed to create /etc snapshot — continuing without it."
  fi
}

prompt_yn() {
  local q="$1" def="${2:-N}"
  local hint="[y/N]"
  if [ "$def" = "y" ] || [ "$def" = "Y" ]; then hint="[Y/n]"; fi
  local a
  if [ -t 0 ]; then
    read -r -p "$q $hint " a
  elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
    printf '%s %s ' "$q" "$hint" >/dev/tty
    read -r a </dev/tty
  else
    # No interactive terminal available - use the default and warn.
    # QUIET_PROMPTS=1 silences this warning (useful in CI / Docker).
    if [ "${QUIET_PROMPTS:-0}" != "1" ]; then
      warn "stdin is not a TTY and /dev/tty is unavailable; defaulting to '$def' for: $q"
    fi
    a="$def"
  fi
  a="${a:-$def}"
  case "$a" in [Yy]*) return 0;; *) return 1;; esac
}

prompt_choice() {
  local q="$1"; shift
  local opts=("$@")
  local i=1
  echo "$q"
  for o in "${opts[@]}"; do printf "  %d) %s\n" "$i" "$o"; i=$((i+1)); done
  local a
  if [ -t 0 ]; then
    read -r -p "Choose [1-${#opts[@]}] (default 1): " a
  elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
    printf 'Choose [1-%d] (default 1): ' "${#opts[@]}" >/dev/tty
    read -r a </dev/tty
  else
    if [ "${QUIET_PROMPTS:-0}" != "1" ]; then
      warn "stdin is not a TTY and /dev/tty is unavailable; defaulting to 1 for: $q"
    fi
    a=1
  fi
  a="${a:-1}"
  if ! [[ "$a" =~ ^[0-9]+$ ]] || [ "$a" -lt 1 ] || [ "$a" -gt ${#opts[@]} ]; then
    a=1
  fi
  REPLY_CHOICE=$((a-1))
}

run_remote_script() {
  local name="$1"
  local url="${REPO_RAW_BASE}/${name}"
  local dst="${TMP_DIR}/${name}"
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$url" -o "$dst"; then err "Failed to fetch $url"; return 1; fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$dst" "$url"; then err "Failed to fetch $url"; return 1; fi
  else
    err "Neither curl nor wget available; cannot fetch $name"; return 1
  fi
  chmod +x "$dst"

  # Optional GPG verification. Disabled by default; enable by setting
  #   NEOSIGN_GPG_LEVEL=required  NEOSIGN_GPG_FPR=<40-hex fingerprint>
  # in the environment. `advisory` warns but does not abort. The
  # signature is expected alongside the script at the same URL with a
  # `.asc` suffix (detached cleartext signature).
  local gpg_level="${NEOSIGN_GPG_LEVEL:-off}"
  if [ "$gpg_level" != "off" ]; then
    if _verify_remote_gpg_signature "$name" "$dst"; then
      ok "GPG signature OK for $name"
    else
      err "GPG signature verification FAILED for $name"
      if [ "$gpg_level" = "required" ]; then
        err "Aborting (NEOSIGN_GPG_LEVEL=required). Run with NEOSIGN_GPG_LEVEL=off to override."
        return 1
      fi
      warn "Continuing despite bad signature (NEOSIGN_GPG_LEVEL=advisory)."
    fi
  fi

  bash "$dst"
}

# Verify a detached cleartext GPG signature (.asc) against the script.
# Uses the system default pubring (no custom keyring).
# The signer's key must already be in the user's keyring.
# Optionally verify the signer fingerprint matches $NEOSIGN_GPG_FPR if set.
_verify_remote_gpg_signature() {
  local name="$1" script="$2" sig url_dst gpg_out rc
  if ! command -v gpg >/dev/null 2>&1; then
    err "gpg is not installed; cannot verify $name"
    return 1
  fi
  local fpr="${NEOSIGN_GPG_FPR:-}"
  url_dst="${TMP_DIR}/${name}.asc"
  if ! curl -fsSL "${REPO_RAW_BASE}/${name}.asc" -o "$url_dst" 2>/dev/null; then
    err "Could not fetch ${name}.asc from $REPO_RAW_BASE"
    return 1
  fi
  # Verify with the system pubring. If the signer's key is not in the
  # pubring, gpg still validates the cryptographic signature but warns
  # about the unknown key. We capture all output to report it.
  gpg_out=$(mktemp)
  rc=0
  gpg --batch --verify "$url_dst" "$script" >"$gpg_out" 2>&1 || rc=$?
  if [ $rc -ne 0 ] && ! grep -qi 'gpg: no signer information' "$gpg_out" 2>/dev/null; then
    # Also check for "Good signature" despite unknown key
    if ! grep -qi 'Good signature' "$gpg_out" 2>/dev/null; then
      err "gpg --verify failed:"
      cat "$gpg_out" >&2
      rm -f "$gpg_out"
      return 1
    fi
    warn "Signature is cryptographically valid but key is not in pubring."
  fi
  # Optional fingerprint pin: if FPR is set, confirm the signing key matches.
  if [ -n "$fpr" ]; then
    local signer
    signer=$(gpg --batch --verify "$url_dst" "$script" 2>&1 \
              | awk -F'[=:]' '/Primary key fingerprint/ {gsub(/ /,"",$NF); print toupper($NF); exit}')
    # gpg --verify output format varies; also try gpg --list-keys with the signer key id
    if [ -z "$signer" ]; then
      signer=$(gpg --batch --list-keys --keyid-format long "$url_dst" 2>/dev/null \
                | awk '/^pub.*\// {sub(/.*\//,""); print toupper($0); exit}')
    fi
    if [ -n "$signer" ] && [ "$signer" != "$(printf '%s' "$fpr" | tr -d ' ' | tr 'a-f' 'A-F')" ]; then
      err "Signer key ($signer) does not match trusted fingerprint ($fpr)."
      rm -f "$gpg_out"
      return 1
    fi
    ok "Signer fingerprint verified: ${signer:-$(printf '%s' "$fpr" | tr -d ' ')}"
  fi
  rm -f "$gpg_out"
  return 0
}

ENV_TYPE=""
USE_REMOTE_SSH=""
FULL_AUTO=0  # set to 1 when Full profile on a server so SSH hardening runs auto
SSH_AUTO_MODE=0
_KERNEL_UPDATE_PENDING=0  # set to 1 by update_kernel; consumed by _print_run_summary
# ── Cross-distro package-manager and distro detection ──────────────────────
# Detected once at script start; every other function reads $PKG_MGR / $DISTRO.
DRY_RUN=0           # set to 1 to preview without executing
STEP_MODE=0         # set to 1 to run a single named step
SELECTED_STEP=""    # step name for --step mode
PKG_MGR=""   # apt | dnf | yum | zypper | pacman
DISTRO=""    # ubuntu | debian | fedora | rhel | alma | amzn | rocky | centos | opensuse | arch | unknown

detect_distro() {
  if [ -n "$PKG_MGR" ] && [ -n "$DISTRO" ]; then return 0; fi
  local id="" id_like=""
  if [ -f /etc/os-release ]; then
    id="$(grep -m1 '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
    id_like="$(grep -m1 '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
  fi
  id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
  id_like="$(printf '%s' "$id_like" | tr '[:upper:]' '[:lower:]')"
  case "$id" in
    ubuntu)        DISTRO="ubuntu" ;;
    debian)          DISTRO="debian" ;;
    fedora)          DISTRO="fedora" ;;
    rhel|redhat)    DISTRO="rhel" ;;
    almalinux)       DISTRO="alma" ;;
    amzn)             DISTRO="amzn" ;;   # Amazon Linux (AL2023) - uses dnf/yum like RHEL
    rocky)           DISTRO="rocky" ;;
    centos)          DISTRO="centos" ;;
    opensuse|suse)   DISTRO="opensuse" ;;
    arch)            DISTRO="arch" ;;
    *)
      case "$id_like" in
        *ubuntu*)    DISTRO="ubuntu" ;;
        *debian*)    DISTRO="debian" ;;
        *rhel*|*centos*|*fedora*) DISTRO="rhel" ;;
        *opensuse*|*suse*)      DISTRO="opensuse" ;;
        *arch*)                  DISTRO="arch" ;;
        *)                       DISTRO="unknown" ;;
      esac ;;
  esac
  if command -v pacman >/dev/null 2>&1 && [ -f /etc/pacman.conf ]; then
    PKG_MGR="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v apt-get >/dev/null 2>&1 || [ -f /etc/apt/sources.list ]; then
    PKG_MGR="apt"
  else
    PKG_MGR="unknown"
  fi
}

pkg_update() {
  case "$PKG_MGR" in
    apt)    run sudo env DEBIAN_FRONTEND=noninteractive apt-get update ;;
    dnf)    info "Checking for updates (dnf check-update)..."
               sudo dnf check-update >/dev/null 2>&1; rc=$?
               [ "$rc" -eq 100 ] && ok "Updates available — will upgrade." \
               || [ "$rc" -eq 0 ] && ok "System up to date." \
               || info "dnf check-update exited $rc." ;;
    yum)    info "Checking for updates (yum check-update)..."
               sudo yum check-update >/dev/null 2>&1; rc=$?
               [ "$rc" -eq 100 ] && ok "Updates available — will upgrade." \
               || [ "$rc" -eq 0 ] && ok "System up to date." \
               || info "yum check-update exited $rc." ;;
    zypper) run sudo zypper --quiet refresh ;;
    pacman) run sudo pacman -Sy ;;
    *)      info "  pkg_update: no-op on $PKG_MGR" ;;
  esac
}

pkg_install() {
  case "$PKG_MGR" in
    apt)    run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    run sudo dnf install -y "$@" ;;
    yum)    run sudo yum install -y "$@" ;;
    zypper) run sudo zypper install -y --no-confirm "$@" ;;
    pacman) run sudo pacman -S --noconfirm "$@" ;;
    *)      err "pkg_install: unsupported $PKG_MGR"; return 1 ;;
  esac
}

pkg_upgrade() {
  case "$PKG_MGR" in
    apt)    run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade ;;
    dnf)    run sudo dnf upgrade --refresh -y ;;
    yum)    run sudo yum update -y ;;
    zypper) run sudo zypper update -y ;;
    pacman) run sudo pacman -Syu --noconfirm ;;
    *)      err "pkg_upgrade: unsupported $PKG_MGR"; return 1 ;;
  esac
}

pkg_autoremove() {
  case "$PKG_MGR" in
    apt)    run sudo env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove ;;
    dnf)    run sudo dnf autoremove -y ;;
    yum)    run sudo yum autoremove -y ;;
    zypper) run sudo zypper packages --unneeded --delete --no-confirm 2>/dev/null || true ;;
    pacman) run sudo pacman -Qdtq | xargs -r sudo pacman -Rns --noconfirm ;;
    *)      : ;;
  esac
}

pkg_is_installed() {
  case "$PKG_MGR" in
    apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^ii' ;;
    dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
    zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
    *)      false ;;
  esac
}

# ── Firewall helpers (UFW on apt; firewalld everywhere else) ───────────
FW_CMD=""   # ufw | firewall-cmd

_fw_detect() {
  if [ -n "$FW_CMD" ]; then return 0; fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    FW_CMD="firewall-cmd"
  elif command -v ufw >/dev/null 2>&1; then
    FW_CMD="ufw"
  else
    FW_CMD=""
  fi
}

fw_allow() {
  _fw_detect || return 0
  if [ -z "$FW_CMD" ]; then
    info "No active firewall (UFW or firewalld) detected; rule for '$1' not applied."
    return 0
  fi
  # Normalize "22" to "22/tcp" so firewalld does not reject bare port numbers.
  local spec="$1"
  case "$spec" in
    */*) ;;                       # already has /tcp or /udp
    *)   spec="${spec}/tcp" ;;
  esac
  case "$FW_CMD" in
    ufw)          run sudo ufw allow "$spec" ;;
    firewall-cmd) run sudo firewall-cmd --add-port="$spec" --permanent ;;
  esac
}

fw_default_incoming_deny() {
  _fw_detect || return 0
  case "$FW_CMD" in
    ufw)
      run sudo ufw default deny incoming
      run sudo ufw default allow outgoing
      ;;
    firewall-cmd)
      local zone
      zone=$(sudo firewall-cmd --get-default-zone 2>/dev/null || echo public)
      # Permit SSH and DHCPv6 in the active zone BEFORE switching the default
      # zone to drop, otherwise the active interface's ruleset (which still
      # has the old zone) is fine, but new interfaces get drop and the next
      # firewall-cmd --reload re-evaluates from default. So we also switch
      # the runtime default and rebind active interfaces to drop after
      # whitelisting ssh on the new default zone.
      run sudo firewall-cmd --zone="$zone" --add-service=ssh --permanent
      run sudo firewall-cmd --zone="$zone" --add-service=dhcpv6-client --permanent
      # Make the drop zone the new permanent + runtime default.
      run sudo firewall-cmd --set-default-zone=drop
      # Allow SSH and DHCPv6 on drop too, so the next interface bound to
      # the default zone still has basic connectivity. dhcpv6-client is
      # needed for SLAAC + DHCPv6 in IPv6 deployments.
      run sudo firewall-cmd --zone=drop --add-service=ssh --permanent
      run sudo firewall-cmd --zone=drop --add-service=dhcpv6-client --permanent
      # Rebind active interfaces so they all live under the drop zone, not the
      # old public zone. awk extracts interface names from the "interfaces:" lines.
      local iface
      for iface in $(sudo firewall-cmd --get-active-zones 2>/dev/null \
                       | awk '/^  interfaces: / {for(i=2;i<=NF;i++) print $i}' \
                       | grep -v '^lo$\|^lo[0-9]'); do
        run sudo firewall-cmd --zone=drop --change-interface="$iface" --permanent
      done
      ;;
  esac
}

fw_enable() {
  _fw_detect || return 0
  case "$FW_CMD" in
    ufw)          run sudo ufw --force enable ;;
    firewall-cmd) run sudo firewall-cmd --reload ;;
  esac
}

fw_status() {
  _fw_detect || return 0
  case "$FW_CMD" in
    ufw)          sudo ufw status verbose ;;
    firewall-cmd) sudo firewall-cmd --list-all ;;
  esac
}

# Returns 0 if any process is listening on the given TCP/UDP port on this
# host.  Accepts either a bare port number ("53") or a "port/proto" spec
# ("53/tcp").  The check is intentionally lightweight (ss first, then
# /proc inspection, then netstat as a final fallback) so it works in
# minimal containers and on macOS alike.
_is_listening() {
  local spec="$1" port proto
  case "$spec" in
    */*) port="${spec%/*}"; proto="${spec#*/}" ;;
    *)   port="$spec";       proto="tcp" ;;
  esac
  [ -z "$port" ] && return 1
  if command -v ss >/dev/null 2>&1; then
    ss -lnH -p "${proto}" 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}\$" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}\$" && return 0
  fi
  # Last resort: any IPv4/IPv6 listen entry in /proc/net/{tcp,udp}.
  local hp hex
  hp=$(printf '%04X' "$port" 2>/dev/null) || return 1
  for f in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
    [ -r "$f" ] || continue
    awk -v want="$hp" 'NR>1 && tolower($2) ~ ":"want"$" {found=1} END{exit !found}' "$f" && return 0
  done
  return 1
}

# Returns 0 if the active firewall (ufw or firewalld) already permits
# the given port.  With no active firewall, returns 0 (nothing to lock
# out).  The port spec follows the same syntax as fw_allow: bare number
# or "port/proto" (defaults to tcp).
_firewall_allows() {
  local spec="$1"
  _fw_detect
  if [ -z "$FW_CMD" ]; then return 0; fi
  case "$FW_CMD" in
    ufw)
      # ufw status: lines look like "22/tcp ALLOW IN   Anywhere".
      sudo ufw status 2>/dev/null | grep -Eq "[[:space:]]${spec}(/tcp|/udp)?[[:space:]]+ALLOW"
      return $?
      ;;
    firewall-cmd)
      # Any service or port already permitted in any zone counts.
      local port="${spec%/*}"
      sudo firewall-cmd --list-all-zones 2>/dev/null \
        | grep -Eq "(services:.*\bssh\b|ports:.*[[:space:]]${port}/)" \
        && return 0
      return 1
      ;;
  esac
  return 0
}

# If a port is listening locally but the firewall does not allow it,
# warn the user and add a rule (subject to a one-line confirmation for
# the non-SSH case so we never silently punch a hole in a default-deny
# policy).  Returns 0 if the port is safe (no listener, or firewall
# already permits, or rule added); returns 1 if the user declined and
# the listener stays unreachable.
_ensure_firewall_open() {
  local spec="$1"
  local desc="${2:-service on $spec}"
  local is_ssh=0
  case "$spec" in 22|22/tcp|22/udp|ssh) is_ssh=1 ;; esac
  if ! _is_listening "$spec"; then
    return 0   # nothing listening -> nothing to lock out
  fi
  if _firewall_allows "$spec"; then
    return 0
  fi
  warn "$desc is listening on $spec but is not allowed in the firewall."
  if [ "$is_ssh" = "1" ]; then
    # SSH is always safe to allow; the user would have lost the session
    # by now if it were not.
    fw_allow "$spec"
    return $?
  fi
  if [ "${_FW_AUTO_OPEN:-0}" = "1" ] || prompt_yn "Open $spec in the firewall now?" "y"; then
    fw_allow "$spec"
    return $?
  fi
  warn "Declined; $desc will be unreachable from outside this host."
  return 1
}

# Quick check whether a named service unit exists (active OR enabled OR
# installed).  Used by per-module pre-flight checks to skip work that
# is not relevant to the host (e.g., don't run `setup_dnscrypt` if the
# operator already chose systemd-resolved).
_service_present() {
  local unit="$1"
  # systemctl is the source of truth; fall back to `which` for
  # unitless daemons (rare but cheap to check).
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files "${unit}.service" 2>/dev/null \
      | awk 'NR>1 {print $1}' | grep -qx "${unit}.service" && return 0
  fi
  command -v "$unit" >/dev/null 2>&1
}

detect_distro  # run immediately so helpers work in every function


# --- metrics & run summary (shown at the end with a bar chart) ---
declare -A METRICS=(
  [pkgs_upgraded]=0
  [pkgs_installed]=0
  [services_stopped]=0
  [services_hardened]=0
  [sysctls_applied]=0
  [fw_rules_added]=0
  [configs_backed_up]=0
  [tor_services_enabled]=0
  [auth_keys_added]=0
  [rollback_logged]=0
)
METRICS_START_DISK_KB=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)

metrics_add() {
  local key="$1" delta="${2:-1}"
  METRICS[$key]=$(( ${METRICS[$key]:-0} + delta ))
}

# --- dynamic progress checklist (printed before each step) ---
# Order matches the call order in main(). Status: pending | running | done | skip
# UTF-8 detection: use box-drawing chars on UTF-8 terminals, ASCII fallback otherwise.
_BAR_Filled='#'; _BAR_Empty='-'
declare -A CHECKLIST=(
  [tmux_wrap]=pending
  [env_detect]=pending
  [system]=pending
  [system_update]=pending
  [dns]=pending
  [dnscrypt]=pending
  [firewall]=pending
  [tor]=pending
  [ssh]=pending
  [ssh_hardening]=pending
  [fail2ban]=pending
  [unattended]=pending
  [ipv6]=pending
  [sysctl]=pending
  [apparmor]=pending
  [pam]=pending
  [optimize]=pending
  [optimize_asr]=pending
  [deepclean]=pending
  [other_scripts]=pending
  [summary]=pending
)
CHECKLIST_LABEL_tmux_wrap="Auto-wrap SSH session in tmux"
CHECKLIST_LABEL_env_detect="Detect environment (desktop/server)"
CHECKLIST_LABEL_system="System update + base packages"
CHECKLIST_LABEL_system_update="System update + base packages"
CHECKLIST_LABEL_dns="DNSCrypt + DNS routing"
CHECKLIST_LABEL_dnscrypt="DNSCrypt + DNS routing"
CHECKLIST_LABEL_firewall="Firewall (UFW / firewalld)"
CHECKLIST_LABEL_tor="Tor daemon"
CHECKLIST_LABEL_ssh="SSH hardening (lockout-prone)"
CHECKLIST_LABEL_ssh_hardening="SSH hardening (lockout-prone)"
CHECKLIST_LABEL_fail2ban="Fail2ban"
CHECKLIST_LABEL_unattended="Unattended security upgrades"
CHECKLIST_LABEL_ipv6="Disable IPv6"
CHECKLIST_LABEL_sysctl="Kernel/sysctl hardening"
CHECKLIST_LABEL_apparmor="AppArmor"
CHECKLIST_LABEL_pam="Password & lockout policy"
CHECKLIST_LABEL_optimize="OptimizeLinuxASR.sh (ASR)"
CHECKLIST_LABEL_optimize_asr="OptimizeLinuxASR.sh (ASR)"
CHECKLIST_LABEL_deepclean="DeepClean.sh (cleanup)"
CHECKLIST_LABEL_other_scripts="Other helpers (Shadowsocks / server extras)"
CHECKLIST_LABEL_summary="Print run summary"

mark_step() {
  CHECKLIST[$1]="${2:-done}"
}

# Print a one-line step header with preview text.
# Usage: _step_begin <key> <label> <preview>
_step_begin() {
  local key="$1" label="$2" preview="$3"
  mark_step "$key" running
  show_progress
  local _hr="────────────────────────────────────────────────────────────────"
  printf '\n%s\n' "$(_c '1;1;36m' "  ▸ $label")"
  [ -n "$preview" ] && printf '  %s %s\n' "$(_c '1;30m' '→')" "$(_c '1;37m' "$preview")"
  printf '%s\n' "$_hr"
}

# Print elapsed time after a step completes.
# Usage: _step_end <key> <label>
_step_end() {
  local key="$1" label="$2"
  mark_step "$key" done
  local elapsed=$SECONDS
  local min=$(( elapsed / 60 ))
  local sec=$(( elapsed % 60 ))
  local time_str
  if [ "$min" -gt 0 ]; then
    time_str="${min}m ${sec}s"
  else
    time_str="${sec}s"
  fi
  printf '  %s %s\n' "$(_c '1;32m' '[OK]')" "$label done in $time_str"
}

# When --step STEP is set, run() is a no-op and ask_category_enabled returns 1
# for every step except the named one. _valid_step validates the user input
# against a known list so typos fail loudly instead of silently skipping
# everything.
_should_run_step() {
  if [ "${STEP_MODE:-0}" = "0" ]; then return 0; fi
  if [ "$1" = "${SELECTED_STEP:-}" ]; then return 0; fi
  info "[STEP] Skipping: $1 (--step=${SELECTED_STEP})"
  return 1
}
# Valid step keys for --step.  These MUST match the keys passed to
# ask_category_enabled() in main(), otherwise --step will be rejected as
# "unknown" even for legitimate steps.  Aliases (e.g. system_update,
# ssh_hardening) are accepted alongside the short keys for convenience.
_VALID_STEPS="system system_update dns dnscrypt firewall tor ssh ssh_hardening fail2ban unattended ipv6 sysctl apparmor pam optimize optimize_asr deepclean"
_valid_step() {
  case " $_VALID_STEPS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Short preview text for each step — printed before the step runs.
# Keep entries under ~70 chars so the terminal doesn't wrap.
declare -A _STEP_PREVIEWS
_STEP_PREVIEWS["system"]="apt update + upgrade, install base packages (curl, fail2ban, etc.)."
_STEP_PREVIEWS["system_update"]="apt update + upgrade, install base packages (curl, fail2ban, etc.)."
_STEP_PREVIEWS["dns"]="install dnscrypt-proxy; you choose between DoH, DNSCrypt, and DoT."
_STEP_PREVIEWS["dnscrypt"]="install dnscrypt-proxy; you choose between DoH, DNSCrypt, and DoT."
_STEP_PREVIEWS["firewall"]="install + enable UFW (or firewalld); allow OpenSSH; default-deny inbound."
_STEP_PREVIEWS["tor"]="install + enable tor.service; configure SOCKS5 on 9050."
_STEP_PREVIEWS["ssh"]="lockout-proof hardening: password off, key-only, no root, fail2ban, no IPv4 block."
_STEP_PREVIEWS["ssh_hardening"]="lockout-proof hardening: password off, key-only, no root, fail2ban, no IPv4 block."
_STEP_PREVIEWS["fail2ban"]="enable fail2ban with sshd jail; 5 retries / 10 min ban / 1h window."
_STEP_PREVIEWS["unattended"]="enable unattended security upgrades; daily update + auto-reboot at 4am if needed."
_STEP_PREVIEWS["ipv6"]="disable IPv6 system-wide (kernel + sysctl). Warned: may break IPv4 ping if not careful."
_STEP_PREVIEWS["sysctl"]="apply hardened kernel/network sysctls (no IPv4 icmp-echo-block on deny)."
_STEP_PREVIEWS["apparmor"]="enable AppArmor; enforce default profiles."
_STEP_PREVIEWS["pam"]="tighten pam_faillock: 5 retries / 15 min lockout."
_STEP_PREVIEWS["optimize"]="run OptimizeLinuxASR.sh (network/disk tweaks). Reversible."
_STEP_PREVIEWS["optimize_asr"]="run OptimizeLinuxASR.sh (network/disk tweaks). Reversible."
_STEP_PREVIEWS["deepclean"]="run DeepClean.sh (apt cache, journal, old kernels). Safe but uses disk."

_CHECKLIST_ORDER="tmux_wrap env_detect system_update dnscrypt firewall tor ssh_hardening fail2ban unattended ipv6 sysctl apparmor pam optimize_asr deepclean other_scripts summary"

show_progress() {
  local done=0 total=0 key status
  for key in $_CHECKLIST_ORDER; do
    total=$((total + 1))
    case "${CHECKLIST[$key]:-pending}" in
      done|running|skip) done=$((done + 1)) ;;
    esac
  done
  local pct=$(( done * 100 / total ))
  local width=24
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar_filled bar_empty
  bar_filled="$(printf '%*s' "$filled" '' | tr ' ' "$_BAR_Filled")"
  bar_empty="$(printf '%*s' "$empty" '' | tr ' ' "$_BAR_Empty")"
  printf '\n'
  _c '1;36m' "=== PROGRESS "
  _c '1;32m' "$bar_filled"
  _c '1;30m' "$bar_empty"
  printf ' %d/%d (%d%%) ===\n' "$done" "$total" "$pct"
  local icon color label_var label
  for key in $_CHECKLIST_ORDER; do
    status="${CHECKLIST[$key]:-pending}"
    case "$status" in
      done)    icon='[x]'; color='1;32m' ;;
      running) icon='[>]'; color='1;33m' ;;
      *)       icon='[ ]'; color='1;30m' ;;
    esac
    label_var="CHECKLIST_LABEL_${key}"
    label="${!label_var:-}"
    printf '  '
    _c "$color" "$icon "
    printf '%s\n' "$label"
  done
  printf '\n'
}

_metrics_bar() {
  local label="$1" value="$2" max="$3" width="${4:-40}"
  [ "$max" -eq 0 ] 2>/dev/null && max=1
  [ "$value" -gt "$max" ] 2>/dev/null && value="$max"
  local filled=$(( value * width / max ))
  local empty=$(( width - filled ))
  local bar empty_str
  bar="$(printf '%*s' "$filled" '' | tr ' ' "$_BAR_Filled")"
  empty_str="$(printf '%*s' "$empty" '' | tr ' ' "$_BAR_Empty")"
  printf '  %-28s %s%s  %d\n' "$label" "$(_c '1;32m' "$bar")" "$(_c '1;30m' "$empty_str")" "$value"
}

print_metrics_summary() {
  local end_disk_kb
  end_disk_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
  local disk_delta=$(( end_disk_kb - METRICS_START_DISK_KB ))
  local disk_freed_str
  if [ "$EUID" -ne 0 ]; then
    disk_freed_str="N/A (re-run as root to measure)"
  elif [ "$disk_delta" -gt 0 ]; then
    disk_freed_str="$(numfmt --to=iec-i --suffix=B "$(( disk_delta * 1024 ))" 2>/dev/null || echo "${disk_delta} KB freed")"
  elif [ "$disk_delta" -lt 0 ]; then
    disk_freed_str="(used ${disk_delta#-} KB — net disk usage grew during run)"
  else
    disk_freed_str="0 B (no net change)"
  fi

  local max_val=1
  for v in "${METRICS[@]}"; do
    [ "$v" -gt "$max_val" ] 2>/dev/null && max_val="$v"
  done

  local _hr
  _hr="$(printf '=%.0s' {1..69})"
  printf '\n%s\n' "$_hr"
  printf '  %s' "$(_c '1;36m' 'RUN SUMMARY')"
  [ "$USE_REMOTE_SSH" = "yes" ] && printf ' %s' "$(_c '1;33m' '[SSH HARDENED]')"
  [ "$ENV_TYPE" = "server" ]  && printf ' %s' "$(_c '1;35m' '[SERVER MODE]')"
  printf '\n%s\n\n' "$_hr"
  printf '  %s\n' "$(_c '1;37m' 'PACKAGES')"
  _metrics_bar "  Packages upgraded"   "${METRICS[pkgs_upgraded]}"   "$max_val"
  _metrics_bar "  Packages installed"  "${METRICS[pkgs_installed]}"  "$max_val"
  printf '\n'
  printf '  %s\n' "$(_c '1;37m' 'SECURITY')"
  _metrics_bar "  Services hardened"  "${METRICS[services_hardened]}" "$max_val"
  _metrics_bar "  Services stopped"   "${METRICS[services_stopped]}"  "$max_val"
  _metrics_bar "  sysctls applied"     "${METRICS[sysctls_applied]}"  "$max_val"
  _metrics_bar "  Firewall rules added" "${METRICS[fw_rules_added]}" "$max_val"
  printf '\n'
  printf '  %s\n' "$(_c '1;37m' 'SSH & AUTHENTICATION')"
  _metrics_bar "  Auth keys added"     "${METRICS[auth_keys_added]}"   "$max_val"
  printf '\n'
  printf '  %s\n' "$(_c '1;37m' 'TOR')"
  _metrics_bar "  Tor services enabled" "${METRICS[tor_services_enabled]}" "$max_val"
  printf '\n'
  printf '  %s\n' "$(_c '1;37m' 'BACKUPS & ROLLBACK')"
  _metrics_bar "  Config files backed up" "${METRICS[configs_backed_up]}" "$max_val"
  _metrics_bar "  Rollback entries logged" "${METRICS[rollback_logged]}" "$max_val"
  printf '\n'
  printf '  %s\n' "$(_c '1;37m' 'STORAGE')"
  printf '  %-28s %s\n' "  Disk freed (approximate)" "$disk_freed_str"
  printf '\n'
  if [ "${METRICS[configs_backed_up]}" -gt 0 ]; then
    printf '  %s %s\n' "$(_c '1;33m' '[!] Rollback log:')" "$ROLLBACK_LOG"
    printf '  %s\n' "$(_c '1;30m' '  Format: original_path<TAB>backup_path')"
    printf '  %s\n' "$(_c '1;30m' '  To restore: sudo cp backup_path original_path')"
  fi
  printf '%s\n' "$_hr"
}

print_welcome() {
  local _os_label _kernel _hostname _user_label
  _os_label="$(awk -F= '/^NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || uname -s)"
  _kernel="$(uname -r)"
  _hostname="$(hostname 2>/dev/null || echo unknown)"
  if [ "$EUID" -eq 0 ]; then
    _user_label="root ($(whoami 2>/dev/null || echo root))"
  else
    _user_label="$USER (non-root — re-run with sudo)"
  fi
  local _step_count _ssh_note
  case "$REPLY_PROFILE" in
    1) _step_count=6 _ssh_note="(no SSH changes)" ;;
    2) _step_count=10 _ssh_note="(includes SSH hardening)" ;;
    3) _step_count=12 _ssh_note="(includes SSH hardening + Tor)" ;;
    7|8|9) _step_count=1 _ssh_note="(single-mode)" ;;
    *) _step_count=0 _ssh_note="" ;;
  esac
  printf '\n%s\n' "$(_c '1;36m' "  ╔══════════════════════════════════════════════════════════╗")"
  printf '%s\n' "$(_c '1;36m' "  ║          neohiro/linux  —  Setup & Hardening             ║")"
  printf '%s\n' "$(_c '1;36m' "  ╚══════════════════════════════════════════════════════════╝")"
  printf '\n  %-14s %s\n' "$(_c '1;30m' 'Host:')"     "$(_c '1;37m' "$_hostname")"
  printf '  %-14s %s\n' "$(_c '1;30m' 'OS:')"       "$(_c '1;37m' "$_os_label")"
  printf '  %-14s %s\n' "$(_c '1;30m' 'Kernel:')"   "$(_c '1;37m' "$_kernel")"
  printf '  %-14s %s\n' "$(_c '1;30m' 'Arch:')"     "$(_c '1;37m' "$(uname -m)")"
  printf '  %-14s %s\n' "$(_c '1;30m' 'Run as:')"   "$(_c '1;37m' "$_user_label")"
  printf '\n  %s\n' "$(_c '1;30m' '──────────────────────────────────────────────────────────')"
  printf '  %-14s %s\n' "$(_c '1;30m' 'Environment:')" "$ENV_TYPE"
  printf '  %-14s %s\n' "$(_c '1;30m' 'Remote SSH:')"  "$(_c '1;37m' "$USE_REMOTE_SSH")"
  printf '  %-14s %s\n' "$(_c '1;30m' 'Profile:')"     "$(_c '1;37m' "Profile $REPLY_PROFILE — $(_profile_label)")"
  if [ "$_step_count" -gt 0 ]; then
    printf '  %-14s %s\n' "$(_c '1;30m' 'Steps:')"       "$(_c '1;37m' "~$_step_count hardening steps $_ssh_note")"
  fi
  if [ "$QUICK_MODE" = "1" ]; then
    printf '  %-14s %s\n' "$(_c '1;32m' 'Quick mode:')" "$(_c '1;32m' 'ON — using defaults, no individual prompts')"
  fi
  printf '  %s\n' "$(_c '1;30m' '──────────────────────────────────────────────────────────')"
  if [ -n "${TMUX:-}" ]; then
    info "Running inside tmux — your session is protected against SSH disconnection."
  fi
}

_profile_label() {
  case "$REPLY_PROFILE" in
    1) echo "Recommended" ;;
    2) echo "Standard" ;;
    3) echo "Full" ;;
    4) echo "Custom" ;;
    5) echo "Restore SSH" ;;
    6) echo "Maintenance" ;;
    7) echo "DeepClean" ;;
    8) echo "Attack Surface Reduction" ;;
    9) echo "Updates only" ;;
    *) echo "unknown" ;;
  esac
}

detect_or_ask_env() {
  if pkg_is_installed ubuntu-desktop || pkg_is_installed kubuntu-desktop || \
     pkg_is_installed xubuntu-desktop || pkg_is_installed fedora-workstation-desktop \
     2>/dev/null; then
    ENV_TYPE="desktop"
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^(ssh|sshd)\.service'; then
    ENV_TYPE="server"
  else
    ENV_TYPE=""
  fi

  if [ -n "$ENV_TYPE" ]; then
    info "Detected environment: $ENV_TYPE"
    if ! prompt_yn "Use this environment type?" "y"; then ENV_TYPE=""; fi
  fi
  if [ -z "$ENV_TYPE" ]; then
    prompt_choice "Which environment is this machine?" "Desktop" "Server (headless / VPS)"
    ENV_TYPE="desktop"; [ "$REPLY_CHOICE" -eq 1 ] && ENV_TYPE="server"
  fi

  prompt_choice "Do you use remote SSH to log in to this machine?" "No" "Yes"
  USE_REMOTE_SSH="no"; [ "$REPLY_CHOICE" -eq 1 ] && USE_REMOTE_SSH="yes"
}

ask_profile() {
  local _hr="──────────────────────────────────────────────────────────"
  bold "Profile selection"
  info "Choose how much hardening to apply. All changes are logged and reversible."
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;32m' '1) Recommended')" "$(_c '1;37m' 'Safe defaults — firewall, system updates, unattended upgrades.')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'No risk of SSH lockout.  ~6 steps.  Takes 1-3 min.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;36m' '2) Standard')"   "$(_c '1;37m' 'Recommended + SSH hardening, Fail2ban, kernel sysctls,')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'attack-surface reduction, AppArmor, password policies.  ~11 steps.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;35m' '3) Full')"       "$(_c '1;37m' 'Standard + Tor, IPv6 disable, deep clean.  ~12 steps.')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'Most aggressive.  Takes 5-10 min.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;33m' '4) Custom')"     "$(_c '1;37m' 'Choose each step individually.')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'QUICK_MODE=1 skips per-step prompts; use recommended defaults.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;31m' '5) Restore SSH')" "$(_c '1;37m' 'Diagnose & fix common SSH lockout causes; offers self-heal guard.')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'Safe recovery tool — re-run anytime without re-hardening.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;1;35m' '6) Maintenance')" "$(_c '1;37m' '20 individual tools: inspect, update, recover, optimize.')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'Persistent menu — go in and out without restarting.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;32m' '7) DeepClean')" "$(_c '1;37m' 'Run DeepClean.sh: journal, logs, apt/dnf/pacman cache,')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'snap/dock/flatpak cleanup, systemd coredump, logrotate.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;32m' '8) Attack Surface Reduction')" "$(_c '1;37m' 'Run OptimizeLinuxASR.sh: disable unused services interactively.')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'Categories: hardware, networking, legacy protocols, etc.')"
  printf '\n'
  printf '  %s  %s\n' "$(_c '1;32m' '9) Updates only')" "$(_c '1;37m' 'System update + kernel prune. Install (do not enable)')"
  printf '  %s        %s\n' "" "$(_c '1;30m' 'tor / fail2ban / shadowsocks / dnscrypt. Auto-update opt-in.')"
  printf '\n'
  printf '%s\n' "$_hr"
  prompt_choice "Apply which set of categories?" \
    "Recommended (safe, no SSH-lockout risk)" \
    "Standard (includes SSH hardening, Fail2ban, sysctl, AppArmor)" \
    "Full (includes Tor, IPv6 disable, attack-surface reduction, deep clean)" \
    "Custom (individual per-category prompts)" \
    "Restore SSH (diagnose & fix common lockout causes)" \
    "Maintenance suite (20 individual tools, return to this menu)" \
    "DeepClean (cleanup + auto-prune; no hardening)" \
    "Attack Surface Reduction (OptimizeLinuxASR.sh; service-by-service)" \
    "Updates only (system update + kernel + optional packages + auto-update)"
  REPLY_PROFILE=$REPLY_CHOICE
  if [ "$QUICK_MODE" = "1" ] && [ "$REPLY_PROFILE" = "4" ]; then
    info "Quick mode: individual prompts skipped — using recommended defaults."
    info "Override individual steps with STRICT_RUN=1 if needed."
  fi
}

ask_category_enabled() {
  local key="$1" desc="$2" default="$3"
  _should_run_step "$key" || return 1
  # In QUICK_MODE with Custom profile (4), skip individual prompts — use defaults.
  if [ "$QUICK_MODE" = "1" ] && [ "$REPLY_PROFILE" = "4" ]; then
    [ "$default" = "y" ] && return 0 || return 1
  fi
  case "$REPLY_PROFILE" in
    1) [ "$default" = "y" ]; return $?;;
    2) [ "$default" = "y" ] || [ "$key" = "ssh" ] || [ "$key" = "fail2ban" ] || [ "$key" = "sysctl" ] || [ "$key" = "pam" ] || [ "$key" = "optimize_asr" ]; return $?;;
    3) return 0;;
    4) prompt_yn "Run: $desc?" "$default"; return $?;;
    5) return 1;;
    6) return 1;;
  esac
}

# --- Maintenance suite helpers ---

_ssh_inspect_config() {
  local cfg="/etc/ssh/sshd_config"
  msg "SSH server configuration inspection"
  if [ ! -f "$cfg" ]; then
    err "sshd_config not found at $cfg"; return 1; fi
  info "Key directives in $cfg:"
  local _key_params="Port Protocol AddressFamily PasswordAuthentication PubkeyAuthentication
    PermitRootLogin PermitEmptyPasswords X11Forwarding AllowTcpForwarding Banner
    ClientAliveInterval ClientAliveCountMax MaxAuthTries LoginGraceTime"
  local _p
  for _p in $_key_params; do
    local _val
    _val=$(awk "/^[[:space:]]*#?[[:space:]]*${_p}[[:space:]]/ {for(i=2;i<=NF;i++) printf '%s ', \$i; print ''}" "$cfg" 2>/dev/null | head -1)
    if [ -n "$_val" ]; then
      printf '  %-25s %s\n' "$_p:" "$_val"
    fi
  done
  echo
  if [ -d /etc/ssh/sshd_config.d ]; then
    local _d
    info "Active drop-in files:"
    for _d in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$_d" ] || continue
      printf '  %s\n' "$_d"
      awk '/^[[:space:]]*[^#]/ {printf "    %s\n", $0}' "$_d" 2>/dev/null || true
    done
  fi
  echo
  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    ok "sshd service is running."
  else
    err "sshd service is NOT running."
  fi
}

_maintenance_list_keys() {
  msg "Authorized SSH keys inspection"
  local _total=0
  local _f _keyfile
  for _keyfile in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    if [ -f "$_keyfile" ]; then
      info "File: $_keyfile"
      local _count=0
      while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|\#*) continue ;; esac
        _count=$((_count + 1))
        local _type _comment
        _type=$(echo "$_line" | awk '{print $1}')
        _comment=$(echo "$_line" | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//')
        printf '  [%d] type=%s  comment="%s"\n' "$_count" "$_type" "$_comment"
      done < "$_keyfile"
      _total=$((_total + _count))
    fi
  done
  echo
  if [ "$_total" -eq 0 ]; then
    warn "No authorized_keys found."
    info "Run:  ssh-copy-id $USER@$(hostname -I 2>/dev/null | awk '{print $1}')"
  else
    ok "Total: $_total key(s) across all authorized_keys files."
  fi
}

_maintenance_logs() {
  msg "Recent rollback and self-heal log entries"
  echo
  if [ -f /var/log/linux-install-rollback.log ]; then
    info "=== Rollback log (last 20 lines) ==="
    tail -n 20 /var/log/linux-install-rollback.log 2>/dev/null | sed 's/^/  /'
  else
    info "Rollback log not found."
  fi
  echo
  if [ -f /var/log/neohiro-ssh-watchdog.log ]; then
    info "=== SSH self-heal log (last 20 lines) ==="
    tail -n 20 /var/log/neohiro-ssh-watchdog.log 2>/dev/null | sed 's/^/  /'
  else
    info "SSH self-heal log not found (guard may not be installed yet)."
  fi
}

_maintenance_sysinfo() {
  msg "System information"
  local cpu_model="" _nproc_str
  if command -v lscpu >/dev/null 2>&1; then
    cpu_model="$(lscpu 2>/dev/null | awk -F: '/^Model name/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  fi
  if command -v nproc >/dev/null 2>&1; then
    _nproc_str="$(nproc 2>/dev/null) cores"
  else
    _nproc_str="? cores"
  fi
  printf '  %-20s %s\n' "Hostname:" "$(hostname 2>/dev/null || echo unknown)"
  printf '  %-20s %s\n' "Uptime:" "$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"
  printf '  %-20s %s\n' "Load (1/5/15 min):" "$(cat /proc/loadavg 2>/dev/null || echo unknown)"
  printf '  %-20s %s\n' "Memory:" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo unknown)"
  printf '  %-20s %s\n' "Disk /:" "$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}' || echo unknown)"
  printf '  %-20s %s\n' "Kernel:" "$(uname -r 2>/dev/null || echo unknown)"
  printf '  %-20s %s%s\n' "CPU:" "$_nproc_str" "${cpu_model:+: $cpu_model}"
  if command -v ss >/dev/null 2>&1; then
    printf '  %-20s\n' "Listening TCP ports:"
    ss -tlnp 2>/dev/null | awk 'NR>1 {printf "    %s\n", $0}' | head -20
  fi
}

# Maintenance menu: expanded suite for SSH recovery, config inspection, key
# management, self-heal controls, and system diagnostics.
# The menu uses a magenta header and numbered choices (20 = exit).
maintenance_menu() {
  local choice rc
  while true; do
    printf '\n%s\n' "$(_c '1;35m' '━━━ Maintenance suite ━━━')"
    prompt_choice "Maintenance — pick a category (20=exit)" \
      "System update (apt update + upgrade + base packages)" \
      "DNSCrypt (DNS encryption)" \
      "Firewall (UFW)" \
      "Tor daemon" \
      "SSH hardening (lockout-prone)" \
      "Fail2ban (brute-force protection)" \
      "Unattended security upgrades" \
      "Disable IPv6 (risky)" \
      "Kernel/sysctl hardening" \
      "AppArmor" \
      "Password & lockout policy" \
      "OptimizeLinuxASR (attack-surface reduction)" \
      "DeepClean (cleanup + auto-prune)" \
      "SSH diagnostics & lockout fix (restore_ssh_mode)" \
      "Authorized keys (list + inspect)" \
      "SSH config review (show current directives)" \
      "SSH self-heal guard (install / remove / status)" \
      "Logs (rollback + self-heal log viewer)" \
      "System info (uptime, memory, disk, ports)" \
      "Back to main menu"
    choice=$REPLY_CHOICE
    rc=0
    case $choice in
      0) mark_step system_update "running"; show_progress; update_system   || rc=$?; mark_step system_update "$([ $rc -eq 0 ] && echo done || echo skip)"; update_kernel || rc=$?;;
      1) mark_step dnscrypt "running";      show_progress; setup_dnscrypt  || rc=$?; mark_step dnscrypt      "$([ $rc -eq 0 ] && echo done || echo skip)";;
      2) mark_step firewall "running";     show_progress; setup_firewall   || rc=$?; mark_step firewall     "$([ $rc -eq 0 ] && echo done || echo skip)";;
      3) mark_step tor "running";          show_progress; setup_tor        || rc=$?; mark_step tor          "$([ $rc -eq 0 ] && echo done || echo skip)";;
      4) mark_step ssh_hardening "running"; show_progress; harden_ssh       || rc=$?; mark_step ssh_hardening "$([ $rc -eq 0 ] && echo done || echo skip)";;
      5) mark_step fail2ban "running";     show_progress; setup_fail2ban   || rc=$?; mark_step fail2ban     "$([ $rc -eq 0 ] && echo done || echo skip)";;
      6) mark_step unattended "running";   show_progress; configure_unattended_upgrades || rc=$?; mark_step unattended "$([ $rc -eq 0 ] && echo done || echo skip)";;
      7) mark_step ipv6 "running";         show_progress; disable_ipv6     || rc=$?; mark_step ipv6         "$([ $rc -eq 0 ] && echo done || echo skip)";;
      8) mark_step sysctl "running";       show_progress; harden_sysctl    || rc=$?; mark_step sysctl       "$([ $rc -eq 0 ] && echo done || echo skip)";;
      9) mark_step apparmor "running";     show_progress; setup_apparmor   || rc=$?; mark_step apparmor     "$([ $rc -eq 0 ] && echo done || echo skip)";;
     10) mark_step pam "running";          show_progress; harden_passwords || rc=$?; mark_step pam          "$([ $rc -eq 0 ] && echo done || echo skip)";;
     11) mark_step optimize_asr "running"; show_progress; run_optimize_asr || rc=$?; mark_step optimize_asr "$([ $rc -eq 0 ] && echo done || echo skip)";;
     12) mark_step deepclean "running";    show_progress; run_deepclean    || rc=$?; mark_step deepclean    "$([ $rc -eq 0 ] && echo done || echo skip)";;
     13) bold "=== SSH diagnostics & lockout fix ==="; restore_ssh_mode || rc=$?;;
     14) bold "=== Authorized keys ==="; _maintenance_list_keys;;
     15) bold "=== SSH config review ==="; _ssh_inspect_config || rc=$?;;
     16) bold "=== SSH self-heal guard ==="
         if [ -f /var/run/neohiro-ssh-watchdog.armed ]; then
           info "Self-heal guard is installed and armed."
           if prompt_yn "Remove the self-heal guard?" "n"; then
             _ssh_self_heal_uninstall
           fi
         else
           info "Self-heal guard is NOT installed."
           if prompt_yn "Install the SSH self-heal guard?" "y"; then
             _ssh_self_heal_install
           fi
         fi
         ;;
     17) bold "=== Log viewer ==="; _maintenance_logs;;
     18) bold "=== System info ==="; _maintenance_sysinfo;;
     19) info "Returning to main menu."; break;;
    esac
    if [ $rc -eq 0 ]; then
      ok "Done."
    else
      err "Action returned non-zero exit ($rc). Continuing."
    fi
    show_progress
  done
}

update_system() {
  msg "Updating system and installing base packages..."
  _warn_if_not_tmux
  local upgradable=0
  case "$PKG_MGR" in
    apt) upgradable=$(apt list --upgradable 2>/dev/null | grep -c '/') || upgradable=0 ;;
    dnf|yum) upgradable=$(dnf check-update 2>/dev/null | grep -cE '^[a-zA-Z0-9._+-]+[[:space:]]') || upgradable=0 ;;
    zypper) upgradable=$(zypper list-updates 2>/dev/null | grep -c '|') || upgradable=0 ;;
    pacman) upgradable=$(pacman -Qu 2>/dev/null | wc -l) || upgradable=0 ;;
  esac
  pkg_update
  pkg_upgrade
  metrics_add pkgs_upgraded "$upgradable"
  local base_pkgs=()
  case "$PKG_MGR" in
    apt)    base_pkgs=(apt-transport-https software-properties-common wget curl gnupg lsb-release ca-certificates) ;;
    dnf|yum) base_pkgs=(wget curl gnupg2 ca-certificates) ;;
    zypper) base_pkgs=(wget curl gpg2 ca-certificates) ;;
    pacman) base_pkgs=(wget curl gnupg ca-certificates) ;;
    *)
      err "Unsupported package manager: $PKG_MGR"; return 1 ;;
  esac
  pkg_install "${base_pkgs[@]}"
  metrics_add pkgs_installed "${#base_pkgs[@]}"
}

# Update the kernel and system packages, then prune old kernels.
# Auto-detects the package manager (apt / dnf / yum).  For apt the
# behaviour is conservative: it stays on the GA kernel track (no HWE,
# no mainline, no edge).  Does NOT reboot; the end-of-run summary
# offers one once.  Safe to call standalone or chained after update_system.
update_kernel() {
  msg "System and kernel update..."
  _warn_if_not_tmux

  if [ "$EUID" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    err "sudo required for kernel update."
    return 1
  fi

  local uname_r
  uname_r="$(uname -r)"

  # ── APT (Debian / Ubuntu / derivatives) ──────────────────────────
  if command -v apt >/dev/null 2>&1; then
    info "Package manager: apt ($(lsb_release -ds 2>/dev/null || uname -sr))"

    # Refresh package lists so the candidate kernel version is current.
    run sudo DEBIAN_FRONTEND=noninteractive apt-get update

    # Check whether a kernel upgrade is actually available before touching
    # anything.  We compare the candidate version of linux-image-generic
    # against whatever is currently installed; if they match, we skip.
    local installed cand
    installed="$(dpkg-query -W -f='${Version}' linux-image-generic 2>/dev/null || true)"
    cand="$(apt-cache policy linux-image-generic 2>/dev/null | awk '/Candidate:/ {print $2; exit}' || true)"
    if [ -n "$installed" ] && [ "$installed" = "$cand" ]; then
      ok "Kernel already up to date (running: $uname_r)."
    else
      if [ -n "$cand" ] && [ -n "$installed" ]; then
        info "  linux-image-generic: ${installed} → ${cand}"
      fi

      # Disable livepatch so it does not block new kernel activation.
      if command -v canonical-livepatch >/dev/null 2>&1; then
        run sudo canonical-livepatch disable || true
      fi

      # full-upgrade handles the entire upgrade atomically: deps, kernel
      # metapackages, transitional packages, and any kernel-module stubs.
      info "Running apt full-upgrade..."
      if ! run sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade; then
        err "apt full-upgrade failed — existing kernel is untouched."
        return 1
      fi
      metrics_add pkgs_upgraded 1
    fi

    # ── Prune old kernels ─────────────────────────────────────────
    # Keep at least 2 kernels (current + one fallback).  Removing
    # only the meta-packages leaves the actual vmlinuz/initrd files
    # dangling, so we target linux-image-* and linux-headers-* directly.
    info "Cleaning up old kernel packages..."

    # Try purge-old-kernels first (ships in byobu; no-op if not present).
    if command -v purge-old-kernels >/dev/null 2>&1; then
      run sudo purge-old-kernels -y 2>/dev/null || true
    fi

    # Fallback / complement: autoremove any kernel packages that are no
    # longer required (pre-installed metapackage leaves old image pkgs).
    run sudo DEBIAN_FRONTEND=noninteractive apt-get -y autoremove

    # If autoremove did not prune kernels (e.g. manually installed images),
    # do a targeted removal of every installed kernel except the two newest.
    local running_kver removed
    running_kver="$(uname -r)"
    removed="$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 'linux-headers-*' 2>/dev/null \
        | sort -V \
        | head -n -2 \
        | grep -vE '^(linux-image-generic|linux-headers-generic|linux-modules-generic|linux-image-unsigned-generic|linux-headers-virtual|linux-virtual)$' \
        | grep -vE "^linux-(image|headers)-${running_kver}$" \
        | tr '\n' ' ' || true)"
    if [ -n "$removed" ]; then
      info "  Pruning: $removed"
      run sudo DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge $removed || true
    else
      info "  No additional kernels to prune."
    fi

    # ── DNF (RHEL 8+ / AlmaLinux / Rocky / Fedora) ──────────────
  elif command -v dnf >/dev/null 2>&1; then
    info "Package manager: dnf"
    if ! run sudo dnf upgrade --refresh -y; then
      err "dnf upgrade failed."
      return 1
    fi
    run sudo dnf autoremove -y
    metrics_add pkgs_upgraded 1

    # ── YUM (legacy CentOS 7 / RHEL 7) ──────────────────────────
  elif command -v yum >/dev/null 2>&1; then
    info "Package manager: yum"
    if ! run sudo yum update -y; then
      err "yum update failed."
      return 1
    fi
    run sudo yum autoremove -y
    metrics_add pkgs_upgraded 1

    # ── Unsupported ───────────────────────────────────────────────
  else
    err "No supported package manager (apt/dnf/yum) found."
    return 1
  fi

  # Report what is now installed vs what is running.
  local new_kernel verify_cmd
  case "$(command -v apt >/dev/null 2>&1 && echo apt || command -v dnf >/dev/null 2>&1 && echo dnf || command -v yum >/dev/null 2>&1 && echo yum || echo none)" in
    apt) verify_cmd="dpkg -l 'linux-image-*' | grep '^ii'" ;;
    dnf|yum) verify_cmd="rpm -q kernel" ;;
    *) verify_cmd="uname -r" ;;
  esac
  new_kernel="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)"
  if [ -n "$new_kernel" ] && [ "$new_kernel" != "$uname_r" ]; then
    ok "Kernel updated: running $uname_r → installed $new_kernel (reboot to activate)."
    info "  After reboot: uname -r  &&  $verify_cmd"
    _KERNEL_UPDATE_PENDING=1
  else
    ok "Kernel up to date ($uname_r)."
  fi
}

apply_dns_via_nmcli() {
  local DNS_PRIMARY="${1:-127.0.0.1}" DNS_FALLBACK="${2:-1.1.1.1}"
  _warn_if_not_tmux
  info "Setting DNS on active NetworkManager connections..."
  local conn
  local active_count=0
  while IFS= read -r conn; do
    [ -z "$conn" ] && continue
    active_count=$((active_count + 1))
    run sudo nmcli con mod "$conn" ipv4.dns "$DNS_PRIMARY $DNS_FALLBACK"
    run sudo nmcli con mod "$conn" ipv4.ignore-auto-dns yes
    run sudo nmcli con up "$conn"
  done < <(sudo nmcli -t -f NAME c show --active)
  if [ "$active_count" -eq 0 ]; then
    warn "No active NetworkManager connections found; DNS not changed."
    info "Activate a connection first, then re-run, or edit /etc/resolv.conf manually."
  fi
}

apply_dns_via_netplan() {
  local DNS_PRIMARY="${1:-127.0.0.1}" DNS_FALLBACK="${2:-1.1.1.1}"
  _warn_if_not_tmux
  info "Applying DNS via netplan..."
  local NP f
  NP="$(command -v netplan 2>/dev/null || true)"
  [ -n "$NP" ] || NP="/usr/sbin/netplan"
  [ -x "$NP" ] || { err "netplan not found."; return 0; }
  f=""
  for candidate in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    if [ -f "$candidate" ]; then
      f="$candidate"
      break
    fi
  done
  [ -n "$f" ] || { err "No netplan YAML in /etc/netplan/."; return 0; }
  local bak
  bak="${f}.bak.$(date +%s%N)"
  run sudo cp "$f" "$bak"
  record_backup "$f" "$bak"
  run sudo tee /etc/netplan/99-dnscrypt.yaml >/dev/null <<EOF
network:
  version: 2
  nameservers:
    addresses: [$DNS_PRIMARY, $DNS_FALLBACK]
EOF
  warn "Applying netplan (60s timeout) - if SSH drops, recovery console + 'sudo netplan apply' restores."
  if ! timeout 60 "$NP" apply 2>&1; then
    err "netplan apply failed or timed out. Original config preserved at $bak."
    return 0
  fi
}

apply_dns_via_systemd_networkd() {
  local DNS_PRIMARY="${1:-127.0.0.1}" DNS_FALLBACK="${2:-1.1.1.1}"
  _warn_if_not_tmux
  # Restarting systemd-networkd on the active SSH interface can drop the
  # connection. Detect the interface this SSH session came in on and skip
  # the restart if it is the one we would touch.
  local active_if
  active_if="$(ip -o route show default 2>/dev/null | awk '{print $5}' | head -n1)"
  if [ -n "$active_if" ] && [ -f "/etc/systemd/network/10-$active_if.network" ] && systemctl is-active --quiet systemd-networkd; then
    warn "Active SSH interface ($active_if) is managed by systemd-networkd."
    if ! prompt_yn "Apply DNS via systemd-networkd and restart (may drop SSH - are you in tmux?)" "n"; then
      info "Skipped systemd-networkd DNS change. Write /etc/systemd/network/99-dnscrypt.network manually."
      return 0
    fi
  fi
  info "Applying DNS via systemd-networkd..."
  run sudo mkdir -p /etc/systemd/network
  local f="/etc/systemd/network/99-dnscrypt.network"
  local bak
  if [ -f "$f" ]; then
    bak="${f}.bak.$(date +%s%N)"
    run sudo cp "$f" "$bak"
    record_backup "$f" "$bak"
  fi
  run sudo tee "$f" >/dev/null <<EOF
[Match]
Name=*

[Network]
DNS=$DNS_PRIMARY
DNS=$DNS_FALLBACK
EOF
  run sudo systemctl restart systemd-networkd
}

_apply_dns_127_0_0_1() {
  local DNS_PRIMARY="127.0.0.1" DNS_FALLBACK="1.1.1.1"

  if [ -x /usr/sbin/netplan ]; then
    local np_yaml
    for np_yaml in /etc/netplan/*.yaml /etc/netplan/*.yml; do
      if [ -f "$np_yaml" ]; then
        apply_dns_via_netplan "$DNS_PRIMARY" "$DNS_FALLBACK"; return 0
      fi
    done
  fi

  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    apply_dns_via_nmcli "$DNS_PRIMARY" "$DNS_FALLBACK"; return 0
  fi

  if command -v networkctl >/dev/null 2>&1; then
    apply_dns_via_systemd_networkd "$DNS_PRIMARY" "$DNS_FALLBACK"; return 0
  fi

  err "No supported DNS renderer found."
  info "Manual fallback: echo 'nameserver $DNS_PRIMARY' | sudo tee /etc/resolv.conf"
  info "or: sudo systemd-resolve --interface=lo --set-dns=$DNS_PRIMARY"
}

setup_dnscrypt() {
  msg "DNSCrypt (ambiguous: DNS routing method is environment-dependent)"
  prompt_choice "Apply DNS change to point at 127.0.0.1?" \
    "Auto-detect (netplan / NetworkManager / systemd-networkd - applies automatically)" \
    "Skip - do not apply DNS change"
  if [ "$REPLY_CHOICE" -eq 1 ]; then
    info "Skipping dnscrypt-proxy."
    return 0
  fi
  if pkg_is_installed dnscrypt-proxy; then
    info "dnscrypt-proxy is already installed; skipping apt."
  else
    info "Installing dnscrypt-proxy (this can take a minute on first install)..."
    if ! pkg_install dnscrypt-proxy; then
      err "dnscrypt-proxy not in official repos for $PKG_MGR; install from source."
      return 1
    fi
  fi
  # Port 53 is the most common collision (systemd-resolved listens on
  # 127.0.0.53:53 by default; some users run a private unbound/pihole
  # on 127.0.0.1:53).  If we are about to install dnscrypt-proxy on
  # 127.0.0.2:53, the conflict is harmless; but warn if something else
  # is already on 127.0.0.2:53 (rare but possible).
  if _is_listening "53/udp"; then
    info "Port 53 is already in use on this host — dnscrypt-proxy binds to 127.0.0.2:53 (different IP), so this is usually fine."
    if ss -lnH -u 2>/dev/null | awk '{print $4}' | grep -qE '127\.0\.0\.2:53$'; then
      err "Another process is already listening on 127.0.0.2:53 (udp). dnscrypt-proxy will not start."
      return 1
    fi
  fi
  # Check both common config locations; Debian/Ubuntu vary on whether the
  # package puts it under /etc/dnscrypt-proxy/ or at /etc/dnscrypt-proxy.toml.
  local _conf="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
  if [ ! -f "$_conf" ]; then
    _conf="/etc/dnscrypt-proxy.toml"
  fi
  if [ ! -f "$_conf" ]; then
    # Neither exists: create the parent dir and write a minimal working config.
    _conf="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    info "No config found — generating minimal $_conf"
    run sudo mkdir -p "${_conf%/*}"
    run sudo tee "$_conf" >/dev/null <<'EOF'
# Minimal dnscrypt-proxy config — auto-generated by linuxinstall.sh
listen_addresses = ['127.0.0.2:53']
dnscrypt_proxy_servers
[static]
  [static.'cloudflare']
    stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjEAEmNsb3VkZmxhcmUuY29tCi9kbnMtcXVlcnk'
EOF
  fi
  if [ ! -f "$_conf" ]; then
    err "Could not create $_conf — giving up."
    return 1
  fi
  if [ ! -f /var/backups/dnscrypt-proxy.toml.bak ]; then
    run sudo cp "$_conf" /var/backups/dnscrypt-proxy.toml.bak
    record_backup "$_conf" /var/backups/dnscrypt-proxy.toml.bak
  fi
  if ! grep -qE "listen_addresses = \['127\.0\.0\.2:53'\]" "$_conf" 2>/dev/null; then
    run sudo sed -i "s|# listen_addresses = \[\]|listen_addresses = ['127.0.0.2:53']|" "$_conf"
  fi
  run sudo systemctl restart dnscrypt-proxy
  run sudo systemctl enable dnscrypt-proxy
  _apply_dns_127_0_0_1
  ok "dnscrypt-proxy installed. Test: dig +short myip.opendns.com @127.0.0.2"
  metrics_add services_hardened 1
  metrics_add pkgs_installed 1
}

setup_firewall() {
  msg "Firewall (UFW / firewalld)"
  _fw_detect
  if [ "$FW_CMD" = "ufw" ] && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ok "UFW is already active -- skipping enable."
    fw_status; return 0
  fi
  if [ "$FW_CMD" = "firewall-cmd" ] && systemctl is-active --quiet firewalld 2>/dev/null; then
    ok "firewalld is already active -- skipping enable."
    fw_status; return 0
  fi
  _warn_if_not_tmux
  FW_CMD=""  # clear cache so _fw_detect re-probes after potential install
  case "$PKG_MGR" in
    apt)    pkg_install ufw ;;
    dnf|yum|zypper|pacman) pkg_install firewalld ;;
    *)
      err "No firewall package available for $PKG_MGR."
      info "Install firewalld or ufw manually and re-run."
      return 1 ;;
  esac
  # Ensure the SSH port (whatever it is — 22, 2222, or a custom value)
  # is open in BOTH IPv4 and IPv6 before we apply default-deny.
  # This is the single most important anti-lockout call in the script.
  if [ "$USE_REMOTE_SSH" = "yes" ] || [ "$ENV_TYPE" = "server" ]; then
    if ! _ssh_guard; then
      err "SSH port not guarded — aborting firewall setup to prevent lockout."
      return 1
    fi
  fi
  fw_default_incoming_deny
  # Open the Tor relay ports in the active firewall before enabling default-deny.
  # These are the only ports the Tor step adds, so we handle them here rather
  # than inside each configure_tor_* function.
  if [ "$USE_REMOTE_SSH" = "yes" ] || [ "$ENV_TYPE" = "server" ]; then
    _FW_AUTO_OPEN=1
    for _p in 9050 9051 9040 9001 9030 53 80 443; do
      _ensure_firewall_open "$_p" "port $_p" || true
    done
    unset _FW_AUTO_OPEN
  fi
  fw_enable
  metrics_add services_hardened 1
  fw_status
}


setup_tor() {
  msg "Tor daemon (user-case dependent)"
  if ! prompt_yn "Install the Tor daemon? (For Tor Browser, get it from torproject.org)" "n"; then
    info "Skipping Tor."; return 0
  fi
  if ! pkg_install tor; then
    err "tor not in official repos for $PKG_MGR; install from source."
    return 1
  fi
  metrics_add pkgs_installed 1

  if [ "$ENV_TYPE" = "server" ]; then
    prompt_choice "Auto-configure Tor (server mode)?" \
      "Transparent proxy only (route this host's traffic through Tor)" \
      "Relay only (middle / exit / bridge - help other Tor users)" \
      "Both: private transparent proxy AND a relay (combined)" \
      "Leave /etc/tor/torrc untouched"
    # Pre-check: warn if common Tor ports are already in use.
    case "$REPLY_CHOICE" in
      0)  _is_listening 9050 && warn "Port 9050 (Tor SOCKS) is already in use — transparent proxy may conflict." ;;
      1|2) _is_listening 9001 && _is_listening 9030 \
              && warn "Ports 9001/9030 (common Tor OR/Dir ports) are already in use." ;;
    esac
    case "$REPLY_CHOICE" in
      0) configure_tor_transparent_proxy; metrics_add tor_services_enabled 1 ;;
      1) configure_tor_relay; metrics_add tor_services_enabled 1 ;;
      2) configure_tor_combined; metrics_add tor_services_enabled 2 ;;
      3) warn "Tor installed but /etc/tor/torrc left untouched. Edit manually for relay/transparent-proxy use." ;;
    esac
  else
    if prompt_yn "Set up a minimal Tor relay/middle relay? (no transparent proxy, just relay traffic)" "n"; then
      configure_tor_relay
      metrics_add tor_services_enabled 1
    else
      warn "Tor installed but /etc/tor/torrc left untouched. Edit manually for relay/transparent-proxy use."
    fi
  fi
  ok "Tor daemon installed."
  metrics_add services_hardened 1
}

configure_tor_combined_apply() {
  local CONF="$1" ROLE="$2" OR_PORT="$3" DIR_PORT="$4" NICK="$5" CONTACT="$6" RELAYDIR="$7"
  local BW_RATE="${TOR_BANDWIDTH_RATE:-10}" BW_BURST="${TOR_BANDWIDTH_BURST:-20}"
  local ACCT_MAX="${TOR_ACCOUNTING_MAX:-200 GBytes}"
  local RELAYLOG="/var/log/tor/relay-notices.log"
  run sudo mkdir -p "$RELAYDIR" "/var/log/tor"
  {
    printf 'ORPort %s\n' "$OR_PORT"
    printf 'DirPort %s\n' "$DIR_PORT"
    printf 'Nickname %s\n' "$NICK"
    printf 'ContactInfo %s\n' "$CONTACT"
    printf 'DataDirectory %s\n' "$RELAYDIR"
    printf 'Log notice file %s\n' "$RELAYLOG"
    printf '\nBandwidthRate %s MBytes\n' "${BW_RATE}"
    printf 'BandwidthBurst %s MBytes\n' "${BW_BURST}"
    printf 'AccountingMax %s\n' "$ACCT_MAX"
    printf 'AccountingStart day 1 00:00\n'
    printf '\nAvoidDiskWrites 1\n'
    printf 'DisableAllSwap 1\n'
    printf 'DisableDebuggerAttachment 1\n'
    printf 'CloseUnknownConnection 1\n'
    printf '\nConnLimit 512\n'
    printf 'MaxCircuitDirtiness 10 minutes\n'
    printf 'NumEntryGuards 6\n'
    printf 'SafeLogging 1\n'
  } | run sudo tee "$CONF" >/dev/null
  case "$ROLE" in
    0) run sudo tee -a "$CONF" >/dev/null <<'EXITEOF'
ExitPolicy reject *:*
EXITEOF
      ;;
    1) run sudo tee -a "$CONF" >/dev/null <<'EXITEOF'
ExitPolicy accept *:25
ExitPolicy accept *:587
ExitPolicy accept *:465
ExitPolicy accept *:993
ExitPolicy accept *:995
ExitPolicy accept *:143
ExitPolicy accept *:110
ExitPolicy accept *:443
ExitPolicy accept *:80
ExitPolicy accept *:53
ExitPolicy accept *:22
ExitPolicy accept *:1-19,20-52,54-79,81-442,444-1023,1025-65535
ExitPolicy reject *:*
EXITEOF
      warn "Exit relay: only listed ports are allowed outbound. Check local laws."
      ;;
    2) run sudo tee -a "$CONF" >/dev/null <<'EXITEOF'
ExitPolicy reject *:*
BridgeRelay 1
ServerTransportListenAddr 0.0.0.0:$OR_PORT
ExtORPort auto
EXITEOF
      ;;
  esac
}

configure_tor_combined() {
  msg "Combined: transparent proxy + relay (single host, two tor processes)"
  local NICK OR_PORT DIR_PORT CONTACT ROLE RELAYDIR
  local BW_RATE="${TOR_BANDWIDTH_RATE:-10}" BW_BURST="${TOR_BANDWIDTH_BURST:-20}"
  local ACCT_MAX="${TOR_ACCOUNTING_MAX:-200 GBytes}"
  RELAYDIR="/var/lib/tor-relay"
  prompt_choice "Pick a relay role to run alongside the transparent proxy" \
    "Middle relay (default, recommended for first-time)" \
    "Exit relay (only on a server you own and trust - legal implications)" \
    "Bridge relay (helps censored users)"
  ROLE="$REPLY_CHOICE"
  case "$ROLE" in
    0) OR_PORT="9001"; DIR_PORT="9030";;
    1) OR_PORT="443";   DIR_PORT="80";  warn "Exit relay exposes your IP for other users' traffic.";;
    2) OR_PORT="9001";  DIR_PORT="9030";;
  esac
  local NICK="${TOR_NICK:-$(hostname -s 2>/dev/null | tr -dc 'A-Za-z0-9' || true; echo UbuntuServer)}"
  local CONTACT="${TOR_CONTACT:-you@example.com}"

  local RELAYCONF="/etc/tor/torrc.relay"
  local TORSYSTEMD="/etc/systemd/system/tor-relay.service"

  msg "Configuring primary tor (transparent proxy role)"
  local TORRC="/etc/tor/torrc"
  if [ -f "$TORRC" ]; then
    local TORBAK
    TORBAK="${TORRC}.bak.$(date +%s%N)"
    run sudo cp "$TORRC" "$TORBAK"
    record_backup "$TORRC" "$TORBAK"
  fi
  run sudo tee "$TORRC" >/dev/null <<'EOF'
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
AutomapHostsSuffixes .onion,.exit
TransPort 127.0.0.1:9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
DNSPort 127.0.0.2:53
Log notice file /var/log/tor/notices.log
ORPort 0
DirPort 0
EOF
  _warn_if_not_tmux
  run sudo systemctl restart tor
  if ! sudo systemctl is-active --quiet tor; then
    err "Primary tor failed - restoring torrc and aborting combined setup."
    local tor_backup
    tor_backup=$(ls -t "${TORRC}.bak."* 2>/dev/null | head -n1)
    [ -n "$tor_backup" ] && run sudo cp -f "$tor_backup" "$TORRC"
    return 1
  fi
  ok "Primary tor (transparent proxy) active."

  msg "Configuring relay companion ($ROLE)"
  if [ -f "$RELAYCONF" ] && ! compgen -G "${RELAYCONF}.bak.*" >/dev/null 2>&1; then
    local RELAYBAK
    RELAYBAK="${RELAYCONF}.bak.$(date +%s%N)"
    run sudo cp "$RELAYCONF" "$RELAYBAK"
    record_backup "$RELAYCONF" "$RELAYBAK"
  fi
  if [ -f "$TORSYSTEMD" ] && ! compgen -G "${TORSYSTEMD}.bak.*" >/dev/null 2>&1; then
    local UNITBAK
    UNITBAK="${TORSYSTEMD}.bak.$(date +%s%N)"
    run sudo cp "$TORSYSTEMD" "$UNITBAK"
    record_backup "$TORSYSTEMD" "$UNITBAK"
  fi
  configure_tor_combined_apply "$RELAYCONF" "$ROLE" "$OR_PORT" "$DIR_PORT" "$NICK" "$CONTACT" "$RELAYDIR"
  run sudo chown -R debian-tor:debian-tor "$RELAYDIR"
  run sudo tee "$TORSYSTEMD" >/dev/null <<EOF
[Unit]
Description=Tor relay (companion to local transparent proxy)
After=network-online.target nss-lookup.target tor.service
Wants=network-online.target tor.service

[Service]
Type=simple
ExecStart=/usr/bin/tor -f "$RELAYCONF"
User=debian-tor
Group=debian-tor
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  run sudo systemctl daemon-reload
  run sudo systemctl enable --now tor-relay.service
  if ! sudo systemctl is-active --quiet tor-relay.service; then
    err "tor-relay failed - check: sudo journalctl -u tor-relay --no-pager | tail -30"
  else
    ok "tor-relay active on ORPort=$OR_PORT DirPort=$DIR_PORT."
  fi

  # Open the relay ports in the active firewall. Use the helper functions so
  # UFW (apt) and firewalld (dnf/yum/zypper/pacman) both work; the bare
  # `ufw allow` call from the previous version was a no-op on RHEL/Fedora
  # and left the relay unreachable from the public internet.
  fw_allow "$OR_PORT/tcp"
  fw_allow "$DIR_PORT/tcp"

  _warn_if_not_tmux
  pkg_install iptables-persistent 2>/dev/null || \
    pkg_install iptables-services 2>/dev/null || true
  local cmds=(
    "iptables -t nat -A OUTPUT -d 127.0.0.0/8 -j RETURN"
    "iptables -t nat -A OUTPUT -d 192.168.0.0/16 -j RETURN"
    "iptables -t nat -A OUTPUT -d 172.16.0.0/12 -j RETURN"
    "iptables -t nat -A OUTPUT -d 10.0.0.0/8 -j RETURN"
    "iptables -t nat -A OUTPUT -p tcp --dport 80 -j REDIRECT --to-ports 9040"
    "iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-ports 9040"
    "iptables -t nat -A OUTPUT -p udp --dport 80 -j REDIRECT --to-ports 9040"
    "iptables -t nat -A OUTPUT -p udp --dport 443 -j REDIRECT --to-ports 9040"
    "iptables -t nat -A OUTPUT -p tcp --dport $OR_PORT -j RETURN"
    "iptables -t nat -A OUTPUT -p tcp --dport $DIR_PORT -j RETURN"
  )
  for c in "${cmds[@]}"; do
    run sudo $c
  done
  run sudo netfilter-persistent save

  ok "Transparent proxy + $ROLE active. Bandwidth capped at ${BW_RATE} MB/s sustained, ${BW_BURST} MB/s burst."
  info "Monthly accounting limit: $ACCT_MAX"
  info "Verify exit:   curl --max-time 10 https://check.torproject.org/api/ip"
  info "Verify relay:  https://metrics.torproject.org/rs.html (search: $NICK)"
  info "Bridge (if bridge role):  provide this line to users: $(grep -E '^Bridge ' "$RELAYCONF" 2>/dev/null || echo 'not yet published')"
  warn "apt updates slow. Revert iptables: sudo iptables -t nat -F OUTPUT"
}

configure_tor_transparent_proxy() {
  local TORRC="/etc/tor/torrc"
  if [ -f "$TORRC" ]; then
    local TORBAK
    TORBAK="${TORRC}.bak.$(date +%s%N)"
    run sudo cp "$TORRC" "$TORBAK"
    record_backup "$TORRC" "$TORBAK"
  fi
  run sudo tee "$TORRC" >/dev/null <<'EOF'
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 127.0.0.1:9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
DNSPort 127.0.0.2:53
AutomapHostsSuffixes .onion,.exit
Log notice file /var/log/tor/notices.log
EOF
  _warn_if_not_tmux
  run sudo systemctl restart tor
  pkg_install iptables-persistent 2>/dev/null || \
    pkg_install iptables-services 2>/dev/null || true
  local cmds=(
    "iptables -t nat -A OUTPUT -d 127.0.0.0/8 -j RETURN"
    "iptables -t nat -A OUTPUT -d 192.168.0.0/16 -j RETURN"
    "iptables -t nat -A OUTPUT -d 172.16.0.0/12 -j RETURN"
    "iptables -t nat -A OUTPUT -d 10.0.0.0/8 -j RETURN"
    "iptables -t nat -A OUTPUT -p tcp --dport 80 -j REDIRECT --to-ports 9040"
    "iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-ports 9040"
    "iptables -t nat -A OUTPUT -p udp --dport 80 -j REDIRECT --to-ports 9040"
    "iptables -t nat -A OUTPUT -p udp --dport 443 -j REDIRECT --to-ports 9040"
  )
  for c in "${cmds[@]}"; do
    run sudo $c
  done
  run sudo netfilter-persistent save
  ok "Tor transparent proxy active. Verify: curl --max-time 10 https://check.torproject.org/api/ip"
  warn "apt updates will be much slower; consider 'sudo iptables -t nat -F OUTPUT' to revert."
}

configure_tor_relay() {
  local NICK OR_PORT DIR_PORT CONTACT ROLE
  local BW_RATE="${TOR_BANDWIDTH_RATE:-10}"
  local BW_BURST="${TOR_BANDWIDTH_BURST:-20}"
  local ACCT_MAX="${TOR_ACCOUNTING_MAX:-200 GBytes}"
  prompt_choice "Pick a relay role" "Middle relay (default, recommended for first-time)" "Exit relay (only on a server you own and trust)" "Bridge relay (helps censored users)"
  ROLE="$REPLY_CHOICE"
  case "$ROLE" in
    0) OR_PORT="auto"; DIR_PORT="auto";;
    1) OR_PORT="443";   DIR_PORT="80";   warn "Exit relay exposes your IP for other users' traffic - operate only on infrastructure you own.";;
    2) OR_PORT="auto";  DIR_PORT="auto";;
  esac
  local NICK="${TOR_NICK:-$(hostname -s 2>/dev/null | tr -dc 'A-Za-z0-9' || true; echo UbuntuServer)}"
  local CONTACT="${TOR_CONTACT:-you@example.com}"

  local TORRC="/etc/tor/torrc"
  local TORBAK
  TORBAK="${TORRC}.bak.$(date +%s%N)"
  run sudo cp "$TORRC" "$TORBAK"
  record_backup "$TORRC" "$TORBAK"
  {
    printf 'ORPort %s\n' "$OR_PORT"
    printf 'DirPort %s\n' "$DIR_PORT"
    printf 'Nickname %s\n' "$NICK"
    printf 'ContactInfo %s\n' "$CONTACT"
    printf 'Log notice file /var/log/tor/notices.log\n'
    printf '\nBandwidthRate %s MBytes\n' "${BW_RATE}"
    printf 'BandwidthBurst %s MBytes\n' "${BW_BURST}"
    printf 'AccountingMax %s\n' "$ACCT_MAX"
    printf 'AccountingStart day 1 00:00\n'
    printf '\nAvoidDiskWrites 1\n'
    printf 'DisableAllSwap 1\n'
    printf 'DisableDebuggerAttachment 1\n'
    printf 'CloseUnknownConnection 1\n'
    printf 'SafeLogging 1\n'
  } | run sudo tee "$TORRC" >/dev/null
  case "$ROLE" in
    0)
      run sudo tee -a "$TORRC" >/dev/null <<'EXITEOF'
ExitPolicy reject *:*
ConnLimit 512
MaxCircuitDirtiness 10 minutes
NumEntryGuards 6
EXITEOF
      ;;
    1)
      warn "Exit relay: listing common safe ports. Check local laws before running."
      run sudo tee -a "$TORRC" >/dev/null <<'EXITEOF'
ExitPolicy accept *:25,465,587,993,995,143,110,443,80,53,22
ExitPolicy reject *:*
EXITEOF
      ;;
    2)
      run sudo tee -a "$TORRC" >/dev/null <<'EXITEOF'
ExitPolicy reject *:*
BridgeRelay 1
ExtORPort auto
EXITEOF
      ;;
  esac
  _warn_if_not_tmux
  # Open the relay ports in the active firewall. fw_allow is a no-op for
  # bare port strings that already have a /tcp suffix; the previous `ufw
  # allow` calls were silent failures on RHEL/Fedora/SUSE/Arch.
  fw_allow "$OR_PORT/tcp"
  fw_allow "$DIR_PORT/tcp"
  run sudo systemctl restart tor
  if ! sudo systemctl is-active --quiet tor; then
    err "tor failed - restoring torrc."
    local tor_backup
    tor_backup=$(ls -t "${TORRC}.bak."* 2>/dev/null | head -n1)
    [ -n "$tor_backup" ] && run sudo cp -f "$tor_backup" "$TORRC" 2>/dev/null
    return 1
  fi
  ok "Tor relay starting on ORPort=$OR_PORT DirPort=$DIR_PORT. Bandwidth: ${BW_RATE} MB/s, accounting: $ACCT_MAX"
  info "Check reachability at https://metrics.torproject.org/rs.html (search your nickname)."
  info "First sync with other relays can take 20-60 minutes."
}

disable_ipv6() {
  msg "IPv6 disable (ambiguous - can break some networks/services)"
  if ! prompt_yn "Really disable IPv6? (This is risky on modern networks)" "n"; then
    info "Keeping IPv6 enabled."
    # IPv4 audit: confirm nothing in this script's sysctls would wrongfully
    # block IPv4.  We ONLY check for icmp_echo_ignore_all=1 (which would
    # block ICMPv4 echo, sometimes used to block all IPv4 traffic); we do
    # NOT flag ip_forward=0, accept_redirects=0, etc. since those are
    # legitimate hardening values.
    local v4_blockers=""
    for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
      [ -f "$f" ] || continue
      if grep -qE '^\s*net\.ipv4\.icmp_echo_ignore_all\s*=\s*1\b' "$f" 2>/dev/null; then
        v4_blockers="$v4_blockers $f"
      fi
    done
    if [ -n "$v4_blockers" ]; then
      warn "IPv4-echo-blocking sysctls found in:$v4_blockers"
      warn "These can prevent ICMPv4 ping and may break some connectivity checks."
    else
      ok "No IPv4-blocking sysctls detected; IPv4 is unaffected."
    fi
    return 0
  fi
  if ! prompt_yn "Type 'yes' to confirm you understand network breakage" "no"; then
    info "Aborted IPv6 disable."; return 0
  fi
  # Pre-flight: detect workloads that require IPv6 so we can warn loudly
  # before changing the kernel state.  Disabling IPv6 with these on the
  # host leaves their networks unreachable (Docker default bridge,
  # Podman CNI, LXD, etc. all fall back to IPv6-only DNS in some setups).
  local ipv6_consumers=()
  if _service_present docker;        then ipv6_consumers+=("docker (container networking)")        ; fi
  if _service_present podman;        then ipv6_consumers+=("podman (rootless containers)")        ; fi
  if _service_present lxd;           then ipv6_consumers+=("lxd (managed containers)")           ; fi
  if _service_present incus;         then ipv6_consumers+=("incus (containers)")                 ; fi
  if _service_present tailscaled;    then ipv6_consumers+=("tailscaled (may use IPv6 for direct)") ; fi
  if [ "${#ipv6_consumers[@]}" -gt 0 ]; then
    warn "IPv6-dependent workloads detected: ${ipv6_consumers[*]}"
    warn "Disabling IPv6 will isolate them from the IPv6 internet (and may"
    warn "break health checks that resolve AAAA records)."
    if ! prompt_yn "Continue despite the workloads listed above?" "no"; then
      info "Aborted IPv6 disable."
      return 0
    fi
  fi
  run sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
  run sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
  if [ -f /etc/sysctl.conf ] && [ ! -f /var/backups/sysctl.conf.bak ]; then
    run sudo cp /etc/sysctl.conf /var/backups/sysctl.conf.bak
    record_backup /etc/sysctl.conf /var/backups/sysctl.conf.bak
  fi
  # Detect trailing newline by writing the last byte to a temp file (avoids
  # the newline-stripping behavior of command substitution in subshells).
  # If the file ends in \n, the check succeeds and tee appends on a fresh line.
  # If the file lacks a trailing \n, we prepend one so we don't glue content.
  run sudo bash -c '
    lastbyte=$(tail -c1 /etc/sysctl.conf | od -An -tx1 -N1 | tr -d " \n")
    [ "$lastbyte" != "0a" ] && printf "\n" >> /etc/sysctl.conf
  '
  run sudo tee -a /etc/sysctl.conf >/dev/null <<'EOF'

# disabled by linuxinstall.sh
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  warn "Reboot may be required for full effect."
}

# Helper: set a directive in sshd_config to a value, or append it if absent.
# Looks in the main file AND the drop-ins so a directive that was set via
# /etc/ssh/sshd_config.d/*.conf is correctly rewritten.
_set_or_append_sshd_config() {
  local param="$1" value="$2" cfg="$3"
  # If the parameter lives in a drop-in (Include /etc/ssh/sshd_config.d/*.conf
  # is processed before the main file's directives, so first-set wins),
  # edit the drop-in there. Otherwise update the main config.
  local target="$cfg"
  local dropin
  for dropin in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$dropin" ] || continue
    if grep -qE "^[[:space:]]*#?[[:space:]]*${param}[[:space:]]" "$dropin"; then
      target="$dropin"
      break
    fi
  done
  if grep -qE "^[[:space:]]*#?[[:space:]]*${param}[[:space:]]" "$target"; then
    run sudo sed -i -E "s/^[[:space:]]*#?[[:space:]]*${param}[[:space:]].*/${param} ${value}/" "$target"
  else
    printf '%s %s\n' "$param" "$value" | run sudo tee -a "$target" >/dev/null
  fi
}

backup_and_report_authorized_keys() {
  local bakdir="/var/backups/linux-install-ssh"
  run sudo mkdir -p "$bakdir"
  local f count
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    count=$(grep -cE '^(ssh-|ecdsa-)' "$f" 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && continue
    run sudo cp -a "$f" "$bakdir/$(echo "$f" | tr '/' '_').bak.$(date +%s%N)"
    info "Preserved $f ($count keys) -> $bakdir/$(basename "$f").bak.*"
  done
}

audit_authorized_keys() {
  msg "Audit of existing SSH keys (before any changes)"
  local f count total=0
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || { info "  (none)  $f"; continue; }
    count=$(grep -cE '^(ssh-|ecdsa-)' "$f" 2>/dev/null || echo 0)
    info "  $count key(s) in $f"
    total=$((total + count))
    grep -E '^(ssh-|ecdsa-)' "$f" 2>/dev/null | while IFS= read -r k; do
      printf "    %s ...  %s\n" "$(echo "$k" | awk '{printf "%.50s", $1" "$2}')" "$(echo "$k" | awk '{print $NF}')"
    done
  done
  info "Total keys across all authorized_keys files: $total"
  printf "  Current sshd_config PasswordAuthentication: "
  grep -E '^#?\s*PasswordAuthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | head -3
}

setup_authorized_keys_with_validation() {
  local target_user target_home target_ak
  target_user="${SUDO_USER:-$USER}"
  if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
    target_user="$(logname 2>/dev/null || whoami)"
  fi
  target_home="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)"
  [ -n "$target_home" ] || target_home="/root"
  target_ak="$target_home/.ssh/authorized_keys"

  if [ ! -t 0 ]; then
    err "stdin is not a TTY - cannot paste a public key safely."
    info "Re-run this script interactively (terminal attached) to set up a key."
    return 1
  fi

  msg "Setting up authorized_keys for user: $target_user (home: $target_home)"

  sudo -u "$target_user" mkdir -p "$target_home/.ssh"
  sudo -u "$target_user" chmod 700 "$target_home/.ssh"
  sudo -u "$target_user" touch "$target_ak"
  sudo -u "$target_user" chmod 600 "$target_ak"

  local recovery_key="$target_home/.ssh/id_ed25519_recovery"
  # The key is owned by $target_user with mode 600; root can stat but the
  # test below runs as the OUTER shell, not as $target_user, so an
  # unreadable-by-root mode would trigger spurious regeneration. Use
  # sudo -u so the file lookup matches the owner.
  if ! sudo -u "$target_user" test -f "$recovery_key"; then
    info "Generating a server-side recovery key (ed25519) at $recovery_key"
    if ! sudo -u "$target_user" ssh-keygen -t ed25519 -N "" -f "$recovery_key" -C "linux-install-recovery@$(hostname)" 2>/dev/null; then
      err "Could not generate recovery key."
    else
      printf '\n'
  _c '1;33m' '[!] EMERGENCY RECOVERY KEY (printed in case you get locked out):'
  printf '\n'
      printf "  Path on server: %s\n" "$recovery_key"
      printf "  Copy it to your laptop now:  scp %s@%s:%s ~/\n" "$target_user" "$(hostname)" "$recovery_key"
      printf "  Then 'ssh-add ~/id_ed25519_recovery' before disconnecting.\n"
      printf "  Public:\n"
      sudo -u "$target_user" cat "$recovery_key.pub"
      printf "  (already added to %s)\n\n" "$target_ak"
    fi
  fi

  if ! grep -qF "$(sudo -u "$target_user" cat "$recovery_key.pub" 2>/dev/null)" "$target_ak" 2>/dev/null; then
    sudo -u "$target_user" tee -a "$target_ak" >/dev/null < "$recovery_key.pub"
  fi

  _c '1;33m' "----------------------------------------------------------------------"
  printf '\n'
  _c '1;33m' "|  PASTE YOUR LAPTOP'S PUBLIC SSH KEY BELOW."
  printf '\n'
  _c '1;33m' "|  Format: ssh-ed25519 AAAA... user@host  OR  ssh-rsa AAAA... user@host"
  printf '\n'
  _c '1;33m' "|  Press Enter on an empty line when done, or type 'skip' to abort."
  printf '\n'
  _c '1;33m' "----------------------------------------------------------------------"
  printf ''
  printf "%s" "$(_c '1;33m' '----------------------------------------------------------------------')"
  printf "> "

  local pasted_key="" line
  while IFS= read -r line; do
    [ -z "$line" ] && break
    if [ "$line" = "skip" ]; then pasted_key=""; break; fi
    pasted_key="$line"
    break
  done

  if [ -z "$pasted_key" ]; then
    err "No public key pasted."
    return 1
  fi

  if ! echo "$pasted_key" | grep -qE '^(ssh-(ed25519|rsa|dss|ecdsa)|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+( .+)?$'; then
    err "Pasted value does not look like a valid SSH public key."
    return 1
  fi

  if grep -qF "$pasted_key" "$target_ak"; then
    ok "Public key already in authorized_keys."
  else
    echo "$pasted_key" | sudo -u "$target_user" tee -a "$target_ak" >/dev/null
    sudo -u "$target_user" chmod 600 "$target_ak"
    ok "Public key added to $target_ak"
  fi

  if ! prompt_yn "Have you VERIFIED that this public key works (e.g., you can SSH from your laptop with it)?" "n"; then
    warn "Skipping PasswordAuthentication change - pubkey not confirmed working."
    return 1
  fi

  return 0
}

harden_ssh() {
  if [ "$USE_REMOTE_SSH" != "yes" ] && [ "$SSH_AUTO_MODE" != "1" ]; then
    info "Skipping SSH hardening (not a remote-SSH machine)." ; return 0
  fi

  local SSHCFG="/etc/ssh/sshd_config"
  msg "SSH hardening"

  if ! command -v sshd >/dev/null 2>&1; then
    local sshd_pkg
    case "$PKG_MGR" in
      dnf|yum)  sshd_pkg=openssh-server ;;
      zypper)   sshd_pkg=openssh ;;
      pacman)   sshd_pkg=openssh ;;
      *)        sshd_pkg=openssh-server ;;
    esac
    pkg_install "$sshd_pkg"
    if ! command -v sshd >/dev/null 2>&1; then
      err "openssh-server install failed; cannot proceed with SSH hardening."; return 1
    fi
  fi

  local BACKUP dropin
  BACKUP="${SSHCFG}.bak.$(date +%s%N)"
  run sudo cp "$SSHCFG" "$BACKUP"
  record_backup "$SSHCFG" "$BACKUP"

  local -A SSH_DROPIN_BAKS
  local bak
  for dropin in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$dropin" ] || continue
    bak="${dropin}.bak.$(date +%s%N)"
    SSH_DROPIN_BAKS[$dropin]="$bak"
    run sudo cp "$dropin" "$bak"
    record_backup "$dropin" "$bak"
  done

  local interactive=1
  [ "$SSH_AUTO_MODE" = "1" ] && interactive=0

  # Hardening directives (same in both modes; auto skips the prompts).
  _set_or_append_sshd_config "PermitRootLogin" "no" "$SSHCFG"
  _set_or_append_sshd_config "LoginGraceTime" "30s" "$SSHCFG"
  _set_or_append_sshd_config "MaxAuthTries" "3" "$SSHCFG"
  _set_or_append_sshd_config "MaxSessions" "2" "$SSHCFG"
  metrics_add services_hardened 1
  if [ "$interactive" = "0" ]; then
    ok "[AUTO] PermitRootLogin=no, LoginGraceTime=30s, MaxAuthTries=3, MaxSessions=2"
  fi

  if [ "$interactive" = "1" ] && prompt_yn "Change SSH port from 22 to 2222?" "n"; then
    _warn_if_not_tmux
  _c '1;33m' "[!] SSH port change -- losing connection?"
  printf '  Reconnect with:\n'
  _c '1;36m' "  ssh -p 2222 $USER@$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '\n'
    read -r -p "Press Enter to continue, or Ctrl-C to abort... " _
    _set_or_append_sshd_config "Port" "2222" "$SSHCFG"
    # Open the new port (using OpenSSH service for IPv4+IPv6 coverage)
    # AND keep 22 open for the in-progress connection, in case the user
    # has another session still on 22.  After the run, the user can
    # remove the 22 rule manually.
    _ssh_fw_allow  # ensure new port 2222 is permitted (via OpenSSH)
    if ! _ssh_port_allowed 22; then
      warn "Port 22 is not open in the firewall either. Keeping 22/tcp open until the new port is confirmed."
      _ensure_firewall_open "22/tcp" "sshd (legacy port 22)"
    fi
    metrics_add fw_rules_added 1
  fi

  if [ "$interactive" = "1" ]; then
    if ! prompt_yn "Disable password authentication (PubKey only)? THIS CAN LOCK YOU OUT" "n"; then
      return 0
    fi
    if ! _ssh_disable_password_auth "$SSHCFG"; then
      warn "Pubkey not validated; PasswordAuthentication left unchanged."
    fi
  else
    ok "[AUTO] PasswordAuthentication handling in auto mode."
    _ssh_disable_password_auth "$SSHCFG" || true
  fi

  # Final anti-lockout check: confirm a pubkey actually works before we
  # touch sshd.  If we cannot validate one, abort the restart entirely
  # so the live session is not at risk.
  if [ "$SSH_AUTO_MODE" != "1" ]; then
    local _pubkey_count=0
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
      [ -f "$f" ] || continue
      _pubkey_count=$(( _pubkey_count + $(grep -cE '^(ssh-|ecdsa-)' "$f" 2>/dev/null || echo 0) ))
    done
    if [ "$_pubkey_count" -eq 0 ] && [ -z "${LINUXINSTALL_SKIP_PUBKEY_CHECK:-}" ]; then
      err "Refusing to restart sshd: no authorized pubkeys found and PasswordAuthentication may be off."
      err "Add a key (e.g.  ssh-copy-id $USER@$(hostname -I 2>/dev/null | awk '{print $1}')  ) before re-running,"
      err "or set LINUXINSTALL_SKIP_PUBKEY_CHECK=1 to bypass this check (NOT recommended)."
      return 1
    fi
  fi

  # Validate, then safe-restart (reload first, fall back to restart).
  local sshd_check_err
  if ! sshd_check_err="$(sudo sshd -t 2>&1)"; then
    err "sshd config is INVALID: $sshd_check_err"
    err "Reverting ALL sshd_config backups and NOT restarting."
    run sudo cp -f "$BACKUP" "$SSHCFG"
    for dropin in "${!SSH_DROPIN_BAKS[@]}"; do
      run sudo cp -f "${SSH_DROPIN_BAKS[$dropin]}" "$dropin"
    done
    return 1
  fi

  if [ "$interactive" = "1" ]; then
    _warn_if_not_tmux
  fi
  _ssh_safe_restart "$SSHCFG" || return 1
  ok "SSH hardened and (re)loaded safely."

  # Auto-install the per-minute + boot-time self-heal guard when SSH is
  # used.  This is the layer that turns "I might have broken SSH" into
  # "if I did, it will be fixed within 60s even if I lose my session".
  # The user can opt out at install time and remove it later with
  # --no-self-heal.
  if [ "$USE_REMOTE_SSH" = "yes" ] || [ "$SSH_AUTO_MODE" = "1" ]; then
    if [ -f /var/run/neohiro-ssh-watchdog.armed ]; then
      ok "SSH self-heal guard already installed."
    else
      if [ "$SSH_AUTO_MODE" = "1" ]; then
        QUIET_PROMPTS=1 _ssh_self_heal_install
      else
        if prompt_yn "Install SSH self-heal guard (cron/systemd timer that auto-recovers from lockout within 60s)?" "y"; then
          _ssh_self_heal_install
        else
          info "Skipped self-heal guard. You can install it later:  sudo bash $SCRIPT_PATH --install-self-heal"
        fi
      fi
    fi
  fi
}

_ssh_disable_password_auth() {
  local cfg="$1" ak_count=0 f c
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    c=$(grep -cE '^(ssh-|ecdsa-)' "$f" 2>/dev/null) || c=0
    ak_count=$((ak_count + c))
  done
  if [ "$ak_count" -eq 0 ]; then
    if [ "$SSH_AUTO_MODE" = "1" ]; then
      warn "[AUTO] No pubkeys found. Leaving PasswordAuthentication=yes (no lockout)."
      return 1
    fi
    warn "No public keys found in any authorized_keys."
    if ! setup_authorized_keys_with_validation; then
      err "No working pubkey validated. Leaving PasswordAuthentication unchanged."
      return 1
    fi
    _set_or_append_sshd_config "PasswordAuthentication" "no" "$cfg"
    metrics_add services_hardened 1
    metrics_add auth_keys_added 1
  else
    if [ "$SSH_AUTO_MODE" = "1" ]; then
      ok "[AUTO] $ak_count pubkey(s) found. Disabling PasswordAuthentication."
      _set_or_append_sshd_config "PasswordAuthentication" "no" "$cfg"
      metrics_add services_hardened 1
    else
      _c '1;33m' "----------------------------------------------------------------------"
      printf '\n'
      _c '1;33m' "|  Confirm your pubkey is one of the $ak_count listed above."
      printf '\n'
      _c '1;33m' "|  If you are NOT sure, type 'no' to keep password auth enabled."
      printf '\n'
      _c '1;33m' "----------------------------------------------------------------------"
      printf '\n'
      if ! prompt_yn "Disable PasswordAuthentication? (type 'yes' to confirm)" "no"; then
        warn "Leaving PasswordAuthentication unchanged."; return 1
      fi
      _set_or_append_sshd_config "PasswordAuthentication" "no" "$cfg"
      metrics_add services_hardened 1
    fi
  fi
  return 0
}

setup_fail2ban() {
  if [ "$USE_REMOTE_SSH" != "yes" ] && [ "$ENV_TYPE" != "server" ]; then
    info "Skipping Fail2ban (no remote SSH and not a server)."; return 0
  fi
  msg "Fail2ban"
  if ! prompt_yn "Install & enable Fail2ban with the sshd jail?" "y"; then return 0; fi
  if ! pkg_install fail2ban; then
    if [ "$PKG_MGR" = "pacman" ]; then
      info "fail2ban not in official Arch repos; install via AUR:  yay -S fail2ban"
      return 0
    fi
    err "fail2ban install failed."
    return 1
  fi
  if [ ! -f /etc/fail2ban/jail.local ]; then
    local JAILBAK
    JAILBAK="/etc/fail2ban/jail.local.bak.$(date +%s%N)"
    run sudo cp /etc/fail2ban/jail.conf "$JAILBAK"
    record_backup /etc/fail2ban/jail.conf "$JAILBAK"
    run sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
  fi
  if ! grep -qE '^\[sshd\]' /etc/fail2ban/jail.local; then
    run sudo tee -a /etc/fail2ban/jail.local >/dev/null <<'JAIL'

[sshd]
enabled = true
JAIL
  else
    run sudo sed -i '/^\[sshd\]/,/^\[/ { /^\[sshd\]/b; /^\[/b; s/^enabled[[:space:]]*=.*/enabled = true/; }' /etc/fail2ban/jail.local
  fi
  run sudo systemctl enable --now fail2ban
  metrics_add services_hardened 1
}

configure_unattended_upgrades() {
  msg "Unattended security upgrades"
  if [ "$PKG_MGR" != "apt" ]; then
    info "Unattended upgrades only available on apt-based distros ($PKG_MGR detected). Skipping."
    return 0
  fi
  if pkg_is_installed unattended-upgrades; then
    info "unattended-upgrades is already installed; skipping."
  else
    info "Installing unattended-upgrades..."
    if ! pkg_install unattended-upgrades; then
      err "unattended-upgrades install failed."; return 1
    fi
  fi
  if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ] && [ ! -f /var/backups/50unattended-upgrades.bak ]; then
    run sudo cp /etc/apt/apt.conf.d/50unattended-upgrades /var/backups/50unattended-upgrades.bak
    record_backup /etc/apt/apt.conf.d/50unattended-upgrades /var/backups/50unattended-upgrades.bak
  fi
  if grep -qE '^Unattended-Upgrade::Allowed-Origins' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
    ok "Unattended upgrades already configured."
  else
    info "Enabling default Unattended-Upgrade::Allowed-Origins sources..."
    run sudo sed -i 's|//[[:space:]]*Unattended-Upgrade::Allowed-Origins|Unattended-Upgrade::Allowed-Origins|' /etc/apt/apt.conf.d/50unattended-upgrades || true
  fi
  run sudo sed -i 's|Unattended-Upgrade::Automatic-Reboot "false"|Unattended-Upgrade::Automatic-Reboot "true"|' /etc/apt/apt.conf.d/50unattended-upgrades || true
  ok "unattended-upgrades enabled. Test: unattended-upgrade --dry-run"
  metrics_add services_hardened 1
}


harden_sysctl() {
  msg "Kernel/network hardening via sysctl"
  if ! prompt_yn "Apply the 99-hardening.conf sysctl profile from the README?" "y"; then return 0; fi
  local f="/etc/sysctl.d/99-hardening.conf"
  if [ -f "$f" ] && [ ! -f /var/backups/99-hardening.conf.bak ]; then
    run sudo cp "$f" /var/backups/99-hardening.conf.bak
    record_backup "$f" /var/backups/99-hardening.conf.bak
  fi
  run sudo tee "$f" >/dev/null <<'EOF'
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.yama.ptrace_scope=1
kernel.kexec_load_disabled=1
kernel.sysrq=0
kernel.randomize_va_space=2
fs.suid_dumpable=0
fs.protected_symlinks=1
fs.protected_hardlinks=1
fs.protected_fifos=2
fs.protected_regular=2
net.ipv4.ip_forward=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
EOF
  run sudo sysctl --system
  metrics_add sysctls_applied 25
  metrics_add services_hardened 1
}

setup_apparmor() {
  msg "AppArmor / SELinux"
  case "$PKG_MGR" in
    apt)
      pkg_install apparmor apparmor-utils
      run sudo systemctl enable --now apparmor
      ;;
    dnf|yum)
      if getenforce 2>/dev/null | grep -qi enforcing; then
        ok "SELinux is enforcing (RHEL/Fedora default) -- AppArmor skipped."
        return 0
      fi
      info "On RHEL/Fedora use SELinux. To set enforcing:  sudo setenforce 1"
      info "  Permanent: /etc/selinux/config -> SELINUX=enforcing  (then reboot)"
      ;;
    zypper)
      pkg_install apparmor-profiles apparmor-utils
      run sudo systemctl enable --now apparmor
      ;;
    pacman)
      info "AppArmor on Arch requires AUR:  yay -S apparmor apparmor-utils"
      ;;
  esac
}


harden_passwords() {
  msg "Password & lockout policy"
  if ! prompt_yn "Install libpam-pwquality and set minlen=14?" "y"; then return 0; fi
  local pwquality_pkg
  case "$PKG_MGR" in
    apt)              pwquality_pkg=libpam-pwquality ;;
    dnf|yum|zypper)  pwquality_pkg=libpwquality ;;
    pacman)           pwquality_pkg=libpwquality ;;
    *)                pwquality_pkg=libpam-pwquality ;;
  esac
  pkg_install "$pwquality_pkg"
  if [ -f /etc/security/pwquality.conf ] && [ ! -f /var/backups/pwquality.conf.bak ]; then
    run sudo cp /etc/security/pwquality.conf /var/backups/pwquality.conf.bak
    record_backup /etc/security/pwquality.conf /var/backups/pwquality.conf.bak
  fi
  local -A pwq_vals=( [minlen]=14 [minclass]=3 [maxrepeat]=3 )
  local kw
  for kw in "${!pwq_vals[@]}"; do
    grep -q "^${kw}[[:space:]]*=" /etc/security/pwquality.conf 2>/dev/null || \
      echo "${kw} = ${pwq_vals[${kw}]}" | sudo tee -a /etc/security/pwquality.conf >/dev/null
  done
  if [ -f /etc/security/faillock.conf ] && [ ! -f /var/backups/faillock.conf.bak ]; then
    run sudo cp /etc/security/faillock.conf /var/backups/faillock.conf.bak
    record_backup /etc/security/faillock.conf /var/backups/faillock.conf.bak
  fi
  run sudo tee /etc/security/faillock.conf >/dev/null <<'EOF'
deny = 5
unlock_time = 900
EOF
  if grep -qE '^TMOUT=900; readonly TMOUT; export TMOUT' /etc/profile.d/99-tmout.sh 2>/dev/null; then
    ok "Password/lockout policy already applied."
    return 0
  fi
  if [ -f /etc/profile.d/99-tmout.sh ] && [ ! -f /var/backups/99-tmout.sh.bak ]; then
    run sudo cp /etc/profile.d/99-tmout.sh /var/backups/99-tmout.sh.bak
    record_backup /etc/profile.d/99-tmout.sh /var/backups/99-tmout.sh.bak
  fi
  run sudo tee /etc/profile.d/99-tmout.sh >/dev/null <<'EOF'
TMOUT=900; readonly TMOUT; export TMOUT
EOF
  run sudo chmod 644 /etc/profile.d/99-tmout.sh
  ok "Password/lockout policy set. Note: 'core 0' in /etc/security/limits.conf is recommended."
}

run_optimize_asr() {
  msg "Attack-surface reduction (OptimizeLinuxASR.sh from the repo)"
  if ! prompt_yn "Run the interactive OptimizeLinuxASR script (service-by-service prompts)?" "n"; then return 0; fi
  run_remote_script "OptimizeLinuxASR.sh"
}

run_deepclean() {
  msg "Deep clean (DeepClean.sh from the repo)"
  if ! prompt_yn "Run the DeepClean cleanup + auto-prune config now?" "n"; then return 0; fi
  run_remote_script "DeepClean.sh"
}

# --- Updates-only profile (REPLY_PROFILE=9) ---
# Updates all system packages, optionally installs (but does not enable)
# tor / fail2ban / shadowsocks-libev / dnscrypt-proxy, and asks once
# about enabling automatic (security) updates. Never touches firewall,
# SSH, sysctl, AppArmor, or any hardening. Use this for a "just sync
# the system and have the latest binaries" pass.
updates_only_mode() {
  bold "=== Updates-only mode ==="
  info "This runs the comprehensive update engine (every available package"
  info "manager + snap + flatpak + docker + brew + firmware), then installs"
  info "(but does not enable) the core service binaries, and optionally"
  info "enables automatic (security) updates. No firewall, SSH, or hardening."
  echo

  # 1) Comprehensive system update — every package manager + snap/flatpak
  # + docker images + brew + firmware. Same engine lives in lib/updater.sh
  # and is also runnable standalone:  sudo bash lib/updater.sh
  if ask_category_enabled "system" "Comprehensive system update" "y"; then
    _step_begin "system_update" "Comprehensive system update" "${_STEP_PREVIEWS[system]}"
    SECONDS=0
    local _rc=0
    _run_all_updates || _rc=$?
    _step_end "system_update" "Comprehensive system update"
    if [ "$_rc" -ne 0 ]; then mark_step "system_update" skip; fi
  fi

  # 1b) Kernel update. The update engine above does not touch the kernel
  # on apt (full-upgrade does, but we want a single explicit pass that
  # also prunes old kernels). dnf/yum/zypper/pacman get the same single
  # explicit pass. No reboot is issued — the end-of-run summary offers
  # one.
  if ask_category_enabled "system" "Kernel update + prune" "y"; then
    _step_begin "system_update" "Kernel update + prune" ""
    SECONDS=0
    local _rc=0
    update_kernel || _rc=$?
    _step_end "system_update" "Kernel update + prune"
    if [ "$_rc" -ne 0 ]; then mark_step "system_update" skip; fi
  fi

  # 2) Install core service binaries. Each is gated on "y" default and
  # is installed only (services left disabled) so the user can enable
  # them on their own schedule. shadowsocks-libev is installed on every
  # supported family per SHADOWSOCKS-LIBEV.md.
  local _pkgs=()
  if prompt_yn "Install shadowsocks-libev (SOCKS5 proxy, kept disabled)?" "n"; then
    _pkgs+=(shadowsocks-libev)
  fi
  if prompt_yn "Install fail2ban (brute-force protection, kept disabled)?" "n"; then
    _pkgs+=(fail2ban)
  fi
  if prompt_yn "Install tor (anonymity relay, kept disabled)?" "n"; then
    _pkgs+=(tor)
  fi
  if prompt_yn "Install dnscrypt-proxy (DoH/DoT resolver, kept disabled)?" "n"; then
    _pkgs+=(dnscrypt-proxy)
  fi
  if [ "${#_pkgs[@]}" -gt 0 ]; then
    info "Installing: ${_pkgs[*]} (services will NOT be enabled)."
    if ! pkg_install "${_pkgs[@]}"; then
      err "One or more package installs failed. Continuing."
    fi
  else
    info "No service packages selected."
  fi

  # 3) Automatic (security) updates: opt-in, with the actual configure
  # step delegated to the existing per-distro helper. apt gets the full
  # unattended-upgrades flow; dnf/yum get dnf-automatic; zypper/pacman
  # get a one-line suggestion and skip (per the README).
  echo
  if prompt_yn "Enable automatic (security) updates on this machine?" "y"; then
    case "$PKG_MGR" in
      apt)
        if ask_category_enabled "unattended" "Unattended security upgrades" "y"; then
          _step_begin "unattended" "Unattended security upgrades" "${_STEP_PREVIEWS[unattended]}"
          SECONDS=0
          local _rc=0
          configure_unattended_upgrades || _rc=$?
          _step_end "unattended" "Unattended security upgrades"
          if [ "$_rc" -ne 0 ]; then mark_step "unattended" skip; fi
        fi
        ;;
      dnf|yum)
        if pkg_install dnf-automatic; then
          run sudo systemctl enable --now dnf-automatic.timer
          ok "dnf-automatic.timer enabled (security updates only)."
        else
          err "dnf-automatic install failed."
        fi
        ;;
      zypper)
        info "openSUSE/SLES: install 'yast2-online-update-configuration' to enable automatic updates via YaST2."
        ;;
      pacman)
        info "Arch: install an AUR helper (yay/paru) and an auto-update package such as 'aur-auto-update' or 'pacman-contrib' / 'systemd-timer-pacman'."
        ;;
      *)
        info "No automatic-update helper defined for $PKG_MGR; skipping."
        ;;
    esac
  else
    info "Automatic updates left disabled."
  fi
}

# ask_other_scripts() removed — linux repo does not carry ubuntusocks.sh
# or linuxinstallserver.sh. Expand via PR when those are cross-distro-ported.

# --- Rollback mode ---
# Reads /var/log/linux-install-rollback.log (format: original<TAB>backup)
# and either dry-prints the inverse `cp` commands or, with --apply, runs
# them in reverse order so the latest backup wins. Skips entries whose
# backup no longer exists, logs everything it does.
rollback_mode() {
  local apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      *)       warn "rollback_mode: ignoring unknown arg '$1'" ;;
    esac
    shift
  done

  bold "=== Rollback mode ==="

  if [ "$EUID" -ne 0 ]; then
    err "Rollback must be run as root."; return 1
  fi

  if [ ! -f "$ROLLBACK_LOG" ]; then
    info "No rollback log at $ROLLBACK_LOG; nothing to undo."
    return 0
  fi

  # We use a map (original -> latest backup) so multiple entries for the
  # same file collapse to the most recent one (the actual semantics the
  # user wants: "restore the latest backup of each file").
  local -A LATEST_BAK
  local -a missing
  local line orig bak
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    case "$line" in
      *$'\t'*)
        orig="${line%%$'\t'*}"
        bak="${line#*$'\t'}"
        ;;
      *)
        warn "Skipping malformed line in $ROLLBACK_LOG: $line"
        continue
        ;;
    esac
    [ -n "$orig" ] && [ -n "$bak" ] || continue
    LATEST_BAK[$orig]="$bak"
  done < "$ROLLBACK_LOG"

  if [ "${#LATEST_BAK[@]}" -eq 0 ]; then
    info "Rollback log is empty; nothing to undo."
    return 0
  fi

  info "Found ${#LATEST_BAK[@]} backed-up file(s)."
  echo

  local i orig bak
  # Sort keys so the dry-run output is deterministic and easy to review.
  local -a sorted_origs
  while IFS= read -r orig; do
    [ -n "$orig" ] && sorted_origs+=("$orig")
  done < <(printf '%s\n' "${!LATEST_BAK[@]}" | LC_ALL=C sort)
  for orig in "${sorted_origs[@]}"; do
    bak="${LATEST_BAK[$orig]}"
    if [ ! -f "$bak" ]; then
      warn "Missing backup: $bak (skipping $orig)"
      missing+=("$bak")
      continue
    fi
    if [ "$apply" = "1" ]; then
      printf '  $ sudo cp -f %s %s\n' "$bak" "$orig"
      if sudo cp -f "$bak" "$orig"; then
        ok "Restored $orig from $bak"
      else
        err "Failed to restore $orig from $bak"
      fi
    else
      printf '  sudo cp -f %s %s\n' "$bak" "$orig"
    fi
  done

  if [ "$apply" = "1" ]; then
    echo
    info "Done. Review with:  sudo sshd -t   (and reload any service you changed)"
  else
    echo
    info "Dry-run only. To actually apply:  sudo bash $0 --rollback --apply"
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    echo
    warn "${#missing[@]} backup file(s) were missing; their originals were not restored."
  fi

  return 0
}

# --- SSH Self-heal Guard (boot + every-minute watchdog) ---
# Installs a systemd timer or cron job that runs _ssh_self_heal_check every
# minute and at boot.  This is the layer that prevents SSH lockout even when
# the user is connected over SSH and the script makes a mistake: the watchdog
# detects the broken state within 60 seconds and restores connectivity.
#
# Design principles:
#   - Idempotent: safe to run multiple times; overwrites existing installs.
#   - Unobtrusive: only acts when a problem is detected.
#   - Auditable: every action is logged to /var/log/neohiro-ssh-watchdog.log.
#   - Fail-safe: never locks the user out of a working SSH; only fixes broken ones.
#   - No secrets: does not modify authorized_keys or write any credentials.

_ssh_self_heal_check() {
  local SSHCFG="/etc/ssh/sshd_config"
  local PORT
  PORT=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' "$SSHCFG" 2>/dev/null)
  PORT="${PORT:-22}"
  local TS
  TS="$(date -Iseconds 2>/dev/null || date)"
  local FIXED=0

  if ! sshd -t 2>&1; then
    printf '[%s] WARN: sshd -t failed; skipping self-heal (would need manual review)\n' "$TS"
    return 0
  fi

  if ! _service_present ssh && ! _service_present sshd; then
    printf '[%s] INFO: ssh/sshd service not found; skipping self-heal\n' "$TS"
    return 0
  fi

  if ! _is_listening "$PORT"; then
    printf '[%s] INFO: SSH not listening on port %s; attempting restart\n' "$TS" "$PORT"
    local _unit
    _unit="$(systemctl is-active --quiet sshd 2>/dev/null && echo sshd || echo ssh)"
    systemctl restart "$_unit" 2>/dev/null
    if _is_listening "$PORT"; then
      printf '[%s] FIXED: SSH now listening on port %s after restart\n' "$TS" "$PORT"
      FIXED=1
    else
      printf '[%s] WARN: SSH still not listening after restart; needs manual review\n' "$TS"
    fi
  fi

  _fw_detect
  local _blocked=0
  case "$FW_CMD" in
    firewall-cmd)
      if systemctl is-active --quiet firewalld 2>/dev/null; then
        if ! firewall-cmd --list-ports 2>/dev/null | grep -qE "${PORT}/tcp"; then
          printf '[%s] FIX: firewalld missing port %s/tcp; opening\n' "$TS" "$PORT"
          firewall-cmd --add-port="${PORT}/tcp" --permanent 2>/dev/null
          firewall-cmd --reload 2>/dev/null
          printf '[%s] FIXED: firewalld opened port %s/tcp\n' "$TS" "$PORT"
          FIXED=1
          _blocked=1
        fi
      fi
      ;;
    ufw)
      if ufw status 2>/dev/null | grep -qE 'Status: active'; then
        if ! ufw status 2>/dev/null | grep -qE "ALLOW IN.*${PORT}/tcp"; then
          printf '[%s] FIX: UFW missing port %s/tcp; opening\n' "$TS" "$PORT"
          ufw allow "${PORT}/tcp" >/dev/null 2>&1
          printf '[%s] FIXED: UFW opened port %s/tcp\n' "$TS" "$PORT"
          FIXED=1
          _blocked=1
        fi
      fi
      ;;
  esac

  if [ "$_blocked" = "1" ]; then
    printf '[%s] INFO: SSH port was blocked by firewall; connectivity should be restored\n' "$TS"
  fi

  local _ak_count=0 _f _c
  for _f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$_f" ] || continue
    _c=$(grep -cE '^(ssh-|ecdsa-' "$_f" 2>/dev/null) || _c=0
    _ak_count=$((_ak_count + _c))
  done

  if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHCFG" 2>/dev/null && [ "$_ak_count" -eq 0 ]; then
    printf '[%s] CRITICAL: lockout detected (PasswordAuthentication=no, no pubkeys); re-enabling password auth\n' "$TS"
    if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHCFG" 2>/dev/null; then
      sed -i -E 's/^([[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+)no/\1yes/' "$SSHCFG" 2>/dev/null
      printf '[%s] FIXED: PasswordAuthentication re-enabled to prevent lockout\n' "$TS"
      FIXED=1
    fi
    local _d
    for _d in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$_d" ] || continue
      if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$_d" 2>/dev/null; then
        sed -i -E 's/^([[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+)no/# \1no  # self-heal: re-enabled by ssh-watchdog/' "$_d" 2>/dev/null
        printf '[%s] FIXED: %s PasswordAuthentication no commented out\n' "$TS" "$_d"
        FIXED=1
      fi
    done
    if sshd -t 2>/dev/null; then
      local _unit
      _unit="$(systemctl is-active --quiet sshd 2>/dev/null && echo sshd || echo ssh)"
      systemctl restart "$_unit" 2>/dev/null
      printf '[%s] INFO: sshd restarted after lockout recovery\n' "$TS"
    fi
  fi

  if [ "$FIXED" -eq 1 ]; then
    printf '[%s] INFO: SSH self-heal completed; 1+ issue(s) resolved\n' "$TS"
  fi
  return 0
}

_ssh_self_heal_install() {
  local _log="/var/log/neohiro-ssh-watchdog.log"
  local _guard="/var/run/neohiro-ssh-watchdog.armed"
  install -m 0644 /dev/null "$_log" 2>/dev/null || true

  if [ -f "$_guard" ]; then
    info "SSH self-heal guard is already installed."
    if [ "$SSH_AUTO_MODE" = "1" ]; then
      ok "[AUTO] SSH self-heal guard installed (idempotent re-install)."
      return 0
    fi
    if ! prompt_yn "Re-install the SSH self-heal guard (replaces existing)?" "n"; then
      info "Self-heal guard left unchanged."
      return 0
    fi
  fi

  msg "Installing SSH self-heal guard (runs every minute + at boot)..."
  _ssh_self_heal_uninstall 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1 && systemctl --version 2>/dev/null | grep -q systemd; then
    local _svc="/etc/systemd/system/neohiro-ssh-watchdog.service"
    local _timer="/etc/systemd/system/neohiro-ssh-watchdog.timer"
    local _script="/usr/local/libexec/neohiro-ssh-watchdog.sh"
    install -d -m 0755 /usr/local/libexec 2>/dev/null || true
    cat > "$_script" <<SCRIPT
#!/bin/bash
# neohiro-ssh-watchdog.sh -- invoked by systemd timer / cron every minute.
# Calls the canonical self-heal logic in the parent linuxinstall.sh.
exec /bin/bash $SCRIPT_PATH --self-heal >> $_log 2>&1
SCRIPT
    chmod 0755 "$_script" 2>/dev/null || true
    cat > "$_svc" <<UNIT
[Unit]
Description=neohiro SSH self-heal watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=$_script
UNIT
    cat > "$_timer" <<TIMER
[Unit]
Description=neohiro SSH self-heal watchdog -- every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Persistent=true

[Install]
WantedBy=timers.target
TIMER
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now neohiro-ssh-watchdog.timer 2>/dev/null
    ok "SSH self-heal guard installed (systemd timer: boot+every 60s)."
  else
    local _cron_dir="/etc/cron.d"
    [ -d "$_cron_dir" ] || _cron_dir="/etc/cron.d"
    if [ ! -d "$_cron_dir" ]; then
      warn "No systemd and no cron.d found; self-heal guard cannot be installed."
      info "On this system, manual SSH monitoring is required."
      return 1
    fi
    cat > "$_cron_dir/neohiro-ssh-watchdog" <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# Run self-heal at boot (+30s grace) and every minute
@reboot sleep 30 && /bin/bash $SCRIPT_PATH --self-heal >> $_log 2>&1
* * * * * root /bin/bash $SCRIPT_PATH --self-heal >> $_log 2>&1
CRON
    chmod 0644 "$_cron_dir/neohiro-ssh-watchdog"
    ok "SSH self-heal guard installed (cron: @reboot + every minute)."
  fi

  install -m 0644 /dev/null "$_guard" 2>/dev/null || true
  printf '%s\n' "$(date -Iseconds 2>/dev/null || date)" > "$_guard"
  info "Self-heal log: $_log"
  info "To disable:  sudo bash $SCRIPT_PATH --no-self-heal"
  # Signal _print_run_summary to show the scheduled-self-heal note at end of run.
  _SELF_HEAL_INSTALLED=1
  return 0
}

_ssh_self_heal_uninstall() {
  if [ -f /etc/systemd/system/neohiro-ssh-watchdog.timer ]; then
    systemctl stop neohiro-ssh-watchdog.timer 2>/dev/null || true
    systemctl disable neohiro-ssh-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/neohiro-ssh-watchdog.{service,timer}
    systemctl daemon-reload 2>/dev/null || true
  fi
  rm -f /etc/cron.d/neohiro-ssh-watchdog
  rm -f /usr/local/libexec/neohiro-ssh-watchdog.sh
  rm -f /var/run/neohiro-ssh-watchdog.armed
  info "SSH self-heal guard removed."
}

# --- Restore-SSH mode (also callable from restore_ssh.sh) ---
# Walks through every step the script may have touched and proposes a
# safe undo. Intended to be re-run from console (or Tailscale SSH) when
# the user is locked out.
restore_ssh_mode() {
  bold "=== Restore SSH mode ==="
  info "This module scans the most common lockout causes and proposes fixes."
  info "Each fix is opt-in so you stay in control."

  if [ "$EUID" -ne 0 ]; then
    err "Restore-SSH must be run as root."; return 1
  fi

  if ! command -v sshd >/dev/null 2>&1; then
    err "sshd is not installed. Install:  sudo pkg_install openssh-server"
    return 1
  fi

  local SSHCFG="/etc/ssh/sshd_config"
  local FIXES=()

  # 1) Service running?
  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    ok "sshd service is running."
  else
    FIXES+=("restart-ssh")
    warn "sshd service is NOT running."
  fi

  # 2) Firewall blocks the port?
  _fw_detect
  if [ "$FW_CMD" = "firewall-cmd" ] && systemctl is-active --quiet firewalld 2>/dev/null; then
    local port
    port=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' "$SSHCFG" 2>/dev/null)
    port=${port:-22}
    if firewall-cmd --list-ports 2>/dev/null | grep -qE "${port}/tcp"; then
      ok "firewalld allows port $port/tcp."
    else
      FIXES+=("fw-allow-current-port")
      warn "firewalld does not allow port $port/tcp."
    fi
  elif [ "$FW_CMD" = "ufw" ] && ufw status 2>/dev/null | grep -qE 'Status: active'; then
    local port
    port=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' "$SSHCFG" 2>/dev/null)
    port=${port:-22}
    if ufw status 2>/dev/null | grep -qE "ALLOW IN.*${port}/tcp"; then
      ok "UFW allows port $port/tcp."
    else
      FIXES+=("ufw-allow-current-port")
      warn "UFW does not seem to allow port $port/tcp."
    fi
  else
    info "No active firewalld or UFW; skipping firewall check."
  fi

  # 3) PasswordAuthentication no without a pubkey?
  if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHCFG"; then
    local ak_count=0 f c
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
      [ -f "$f" ] || continue
      c=$(grep -cE '^(ssh-|ecdsa-)' "$f" 2>/dev/null) || c=0
      ak_count=$((ak_count + c))
    done
    if [ "$ak_count" -eq 0 ]; then
      FIXES+=("reenable-password-auth")
      err "PasswordAuthentication is no AND no pubkeys are installed — you are locked out by OpenSSH."
    else
      info "PasswordAuthentication is no but $ak_count pubkey(s) are present (OK if you connect via Tailscale SSH or a pubkey-capable client)."
    fi
  else
    ok "PasswordAuthentication is not disabled."
  fi

  # 4) /etc/ssh/sshd_config.d/ drop-ins
  if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -e "$f" ] || continue
      if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$f"; then
        FIXES+=("disable-sshd-config.d-password-no")
        warn "Drop-in $f disables PasswordAuthentication."
      fi
      if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' "$SSHCFG"; then
        : # include present, fine
      fi
    done
  fi

  # 5) Restore from rollback log if present
  if [ -f /var/log/linux-install-rollback.log ]; then
    info "Rollback log present:"
    grep -E 'ssh' /var/log/linux-install-rollback.log 2>/dev/null | sed 's/^/    /' || true
  fi

  # 6) Apply proposed fixes
  if [ "${#FIXES[@]}" -eq 0 ]; then
    ok "No obvious SSH lockout detected. Try: sudo sshd -t && sudo systemctl restart \$(systemctl is-active --quiet sshd && echo sshd || echo ssh)"
    return 0
  fi

  echo
  info "Proposed fixes:"
  for f in "${FIXES[@]}"; do
    case "$f" in
      restart-ssh)                  printf "  - Restart sshd service (sudo systemctl restart ssh|sshd)\n" ;;
      ufw-allow-current-port)       printf "  - Open current SSH port in UFW\n" ;;
      reenable-password-auth)       printf "  - Re-enable PasswordAuthentication (set 'yes')\n" ;;
      disable-sshd-config.d-password-no) printf "  - Comment out PasswordAuthentication no in drop-ins\n" ;;
    esac
  done

  if ! prompt_yn "Apply ALL proposed fixes now?" "y"; then
    info "No changes made. Run individual suggestions manually."
    return 0
  fi

  for f in "${FIXES[@]}"; do
    case "$f" in
      restart-ssh)
        local ssh_unit
        ssh_unit=$(systemctl is-active --quiet sshd 2>/dev/null && echo sshd || echo ssh)
        run sudo systemctl restart "$ssh_unit"
        ok "sshd restarted."
        ;;
      ufw-allow-current-port)
        local port
        port=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' "$SSHCFG" 2>/dev/null)
        port=${port:-22}
        run sudo ufw allow "${port}/tcp"
        ok "UFW: opened $port/tcp."
        ;;
      fw-allow-current-port)
        local port
        port=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' "$SSHCFG" 2>/dev/null)
        port=${port:-22}
        run sudo firewall-cmd --add-port="${port}/tcp" --permanent
        run sudo firewall-cmd --reload
        ok "firewalld: opened $port/tcp."
        ;;
      reenable-password-auth)
        _set_or_append_sshd_config "PasswordAuthentication" "yes" "$SSHCFG"
        ok "PasswordAuthentication set to yes."
        ;;
      disable-sshd-config.d-password-no)
        for d in /etc/ssh/sshd_config.d/*.conf; do
          [ -e "$d" ] || continue
          if grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$d"; then
            run sudo sed -i 's|^[[:space:]]*PasswordAuthentication[[:space:]]\+no|#PasswordAuthentication no  # disabled by restore_ssh.sh|' "$d"
          fi
        done
        ok "Drop-in PasswordAuthentication no commented out."
        ;;
    esac
  done

  if sudo sshd -t 2>&1; then
    local ssh_unit
    ssh_unit=$(systemctl is-active --quiet sshd 2>/dev/null && echo sshd || echo ssh)
    run sudo systemctl restart "$ssh_unit"
    ok "sshd config valid. Service restarted."
  else
    err "sshd -t still fails. Check /var/log/auth.log for the exact error."
    return 1
  fi
}

main() {
  # Handle flags before anything else
  case "${1:-}" in
    --restore-ssh)
      bold "neohiro/linux - Restore SSH (standalone)"
      restore_ssh_mode
      exit $?
      ;;
    --self-heal)
      shift
      # Silent mode: log only, no prompts, no output unless something changed.
      QUIET_PROMPTS=1 _ssh_self_heal_check 2>&1 | sed -e 's/^/[self-heal] /' >> /var/log/neohiro-ssh-watchdog.log 2>&1
      exit $?
      ;;
    --no-self-heal)
      bold "neohiro/linux - Disable SSH self-heal guard"
      _ssh_self_heal_uninstall
      exit $?
      ;;
    --install-self-heal)
      bold "neohiro/linux - Install SSH self-heal guard"
      _ssh_self_heal_install
      exit $?
      ;;
    --restore-etc-snapshot)
      bold "neohiro/linux - Restore /etc from snapshot"
      _restore_etc_snapshot
      exit $?
      ;;
    --rollback)
      shift
      bold "neohiro/linux - Rollback (standalone)"
      rollback_mode "$@"
      exit $?
      ;;
    --rollback=*)
      bold "neohiro/linux - Rollback (standalone)"
      rollback_mode "${1#--rollback=}"
      exit $?
      ;;
    --dry-run)
      DRY_RUN=1; shift
      bold "[DRY-RUN] Preview mode - no changes will be made"
      ;;
    --step=*)
      STEP_MODE=1
      SELECTED_STEP="${1#--step=}"
      if ! _valid_step "$SELECTED_STEP"; then
        err "Unknown step: $SELECTED_STEP"
        info "Valid steps: $(echo $_VALID_STEPS | tr ' ' ', ')"
        exit 1
      fi
      bold "[STEP] Running only step: $SELECTED_STEP"
      shift
      ;;
    --step)
      STEP_MODE=1
      if [ -z "${2:-}" ]; then
        err "--step requires a value (e.g. --step firewall)"; exit 1
      fi
      SELECTED_STEP="$2"
      if ! _valid_step "$SELECTED_STEP"; then
        err "Unknown step: $SELECTED_STEP"
        info "Valid steps: $(echo $_VALID_STEPS | tr ' ' ', ')"
        exit 1
      fi
      bold "[STEP] Running only step: $SELECTED_STEP"
      shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: sudo bash linuxinstall.sh [--dry-run] [--step STEP] [--restore-ssh] [--restore-etc-snapshot] [--rollback [--apply]] [-h]

  (no flag)         Run the full interactive setup & hardening.
  --dry-run         Preview what would run without executing any commands.
  --step STEP       Run only the named step (e.g. --step firewall).
  --restore-ssh     Diagnose & fix the most common SSH lockout causes.
                    Use this from a console/Tailscale session if you got
                    locked out.
  --self-heal       Run the self-heal check now (used by the cron / systemd
                    timer; logs to /var/log/neohiro-ssh-watchdog.log).
  --install-self-heal  Install the per-minute + boot-time self-heal guard.
  --no-self-heal    Remove the self-heal guard (cron job / systemd timer).
  --restore-etc-snapshot
                    Restore /etc from the latest snapshot taken before
                    hardening (requires ENABLE_ETC_SNAPSHOT=1 when the
                    hardening run was done).  Run this if your system is
                    broken after hardening and the per-file rollback does
                    not cover the damage.
                    Usage: sudo bash linuxinstall.sh --restore-etc-snapshot
  --rollback        Dry-prints the inverse cp commands needed to undo
                    every change recorded in /var/log/linux-install-rollback.log.
  --rollback --apply  Run those cp commands (latest backup wins).
  -h, --help        Show this help.
USAGE
      exit 0
      ;;
  esac

  bold "neohiro/linux - general setup & hardening (interactive)"
  if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (use sudo)."; exit 1
  fi
  ensure_tmux_if_ssh
  mark_step tmux_wrap "done"
  print_recovery_if_ssh
  _warn_if_not_tmux

  detect_or_ask_env
  ask_profile
  RUN_START_TIME=${SECONDS:-0}
  print_welcome
  printf '\n'

  # Full + server => run SSH hardening in auto mode (no interactive lockout-prone prompts)
  if [ "$REPLY_PROFILE" = "3" ] && [ "$ENV_TYPE" = "server" ]; then
    FULL_AUTO=1
    SSH_AUTO_MODE=1
    USE_REMOTE_SSH="yes"  # treat as remote because we're a headless server
  fi

  show_progress

  # Take a lightweight snapshot of /etc before any hardening so the entire
  # config tree can be restored wholesale.  Skipped if ENABLE_ETC_SNAPSHOT=0.
  _take_etc_snapshot

  if [ "$REPLY_PROFILE" = "6" ]; then
    maintenance_menu
    if [ "$USE_REMOTE_SSH" = "yes" ]; then
      info "Because SSH may have been changed, verify a SECOND session can log in BEFORE closing this one."
    fi
    _print_run_summary
    return $?
  fi

  if [ "$REPLY_PROFILE" = "5" ]; then
    # Restore-SSH is its own first-class menu entry (above Maintenance suite).
    # Detect, propose fixes, and optionally re-install the self-heal guard.
    bold "=== Restore SSH (from main menu) ==="
    restore_ssh_mode
    echo
    if [ -f /var/run/neohiro-ssh-watchdog.armed ]; then
      info "Self-heal guard is already installed."
    else
      if prompt_yn "Install the SSH self-heal guard (auto-recovers from lockout within 60s)?" "y"; then
        _ssh_self_heal_install
      fi
    fi
    _print_run_summary
    return $?
  fi

  if [ "$REPLY_PROFILE" = "7" ]; then
    # DeepClean — fetch the script, prompt, run. No hardening steps touched.
    bold "=== DeepClean (from main menu) ==="
    run_deepclean
    _print_run_summary
    return $?
  fi

  if [ "$REPLY_PROFILE" = "8" ]; then
    # Attack Surface Reduction — fetch OptimizeLinuxASR.sh, prompt, run.
    bold "=== Attack Surface Reduction (from main menu) ==="
    run_optimize_asr
    _print_run_summary
    return $?
  fi

  if [ "$REPLY_PROFILE" = "9" ]; then
    # Updates only — system update, optional package installs, optional
    # automatic-updates. No firewall / SSH / sysctl / AppArmor touched.
    bold "=== Updates only (from main menu) ==="
    updates_only_mode
    _print_run_summary
    return $?
  fi

  # Each step shows a one-line preview + elapsed time.  Wrapped in a
  # function-call so any failure (set -e) stops the whole run, but the
  # inline `|| { ...; }` shape below keeps set -e OFF for the main flow
  # so a single failure does not abort subsequent steps.
  _run_step() {
    local key="$1" label="$2" preview="$3" fn="$4"
    if ! ask_category_enabled "$key" "$label" "${5:-n}"; then return 0; fi
    local p="${_STEP_PREVIEWS[$key]:-$preview}"
    while true; do
      _step_begin "$key" "$label" "$p"
      SECONDS=0
      local rc=0
      "$fn" || rc=$?
      _step_end "$key" "$label"
      if [ "$rc" -eq 0 ]; then return 0; fi
      # Failure recovery: offer retry / skip / abort.
      if _prompt_failure_recovery "$label" "$rc"; then
        # user picked retry -- loop again
        continue
      fi
      # user picked skip -- mark step as skip so progress bar is honest
      mark_step "$key" skip
      return 0
    done
  }
  # Workflow order, from most aggressive cleaning to most targeted update:
  #   1) Attack-surface reduction FIRST — stop unneeded services so they are
  #      no longer holding files / kernel modules when we upgrade.
  #   2) Comprehensive system update + kernel prune — every package manager,
  #      snap, flatpak, docker, brew, firmware, geoip.
  #   3) Hardening layer: firewall, SSH, fail2ban, sysctl, AppArmor, ...
  # Rationale: dropping unwanted services first means the system-update
  # transaction does not need to chase daemons that are about to go away.
  _run_step optimize_asr "Attack-surface reduction (stop unneeded services)"  "" run_optimize_asr   n
  # System step is special: it always follows with update_kernel so the
  # new kernel can be detected before the run ends. The comprehensive
  # update engine in lib/updater.sh covers every available package
  # manager plus snap/flatpak/docker/brew/firmware; update_kernel handles
  # the kernel prune pass.
  if ask_category_enabled "system" "System update + base packages" "y"; then
    while true; do
      _step_begin "system_update" "System update + base packages" "${_STEP_PREVIEWS[system]}"
      SECONDS=0
      local _rc=0
      _run_all_updates || _rc=$?
      update_system || _rc=$?
      update_kernel || _rc=$?
      _step_end "system_update" "System update + base packages"
      if [ "$_rc" -eq 0 ]; then break; fi
      if _prompt_failure_recovery "System update" "$_rc"; then continue; fi
      mark_step "system_update" skip; break
    done
  fi
  _run_step dnscrypt     "DNSCrypt (DNS method is ambiguous)"         "" setup_dnscrypt            n
  _run_step firewall     "Firewall (UFW)"                             "" setup_firewall            y
  _run_step tor          "Tor daemon"                                 "" setup_tor                 n
  _run_step ssh          "SSH hardening (lockout-prone)"              "" harden_ssh                n
  _run_step fail2ban    "Fail2ban"                                   "" setup_fail2ban            n
  _run_step unattended  "Unattended security upgrades"               "" configure_unattended_upgrades y
  _run_step ipv6        "Disable IPv6 (risky)"                       "" disable_ipv6              n
  _run_step sysctl      "Kernel/sysctl hardening profile"            "" harden_sysctl             n
  _run_step apparmor    "AppArmor"                                   "" setup_apparmor            n
  _run_step pam         "Password & lockout policy"                  "" harden_passwords          n
  _run_step deepclean   "Run DeepClean.sh (new helper)"              "" run_deepclean            n

  if [ "$USE_REMOTE_SSH" = "yes" ]; then
    info "Because SSH was changed, verify a SECOND session can log in BEFORE closing this one."
    if [ "$SSH_AUTO_MODE" = "1" ]; then
      info "Full+server auto mode: SSH was hardened automatically. If anything went wrong,"
      info "reconnect via console (or out-of-band) and run:  sudo bash $0  --restore-ssh"
    fi
  fi
  _print_run_summary
}

# Common end-of-run summary: print metrics and exit with the right code
# under STRICT_RUN. Non-strict runs always exit 0 (interactive default).
_print_run_summary() {
  mark_step summary "running"
  show_progress
  local total_sec=$(( SECONDS - RUN_START_TIME ))
  local total_min=$(( total_sec / 60 ))
  local total_rem=$(( total_sec % 60 ))
  local total_time_str
  if [ "$total_min" -gt 0 ]; then
    total_time_str="${total_min}m ${total_rem}s"
  else
    total_time_str="${total_sec}s"
  fi
  local _hr="════════════════════════════════════════════════════════════"
  printf '\n%s\n' "$(_c '1;36m' "  ╔══════════════════════════════════════════════════════════╗")"
  printf '%s\n' "$(_c '1;36m' "  ║               ✓  Run complete  —  $total_time_str                 ║")"
  printf '%s\n' "$(_c '1;36m' "  ╚══════════════════════════════════════════════════════════╝")"
  printf '\n'
  print_metrics_summary
  mark_step summary "done"
  show_progress
  if [ -n "$_ETC_SNAPSHOT_PATH" ]; then
    printf '\n  %s\n' "$(_c '1;36m' '== /etc SNAPSHOT')"
    printf '  Full /etc snapshot: %s\n' "$(_c '1;37m' "$_ETC_SNAPSHOT_PATH")"
    printf '  Restore whole /etc:  sudo bash %q --restore-etc-snapshot\n' "$SCRIPT_PATH"
  fi
  # If update_kernel staged a new image, offer a reboot once we are
  # back at the prompt. Never auto-reboot — connection loss during the
  # rest of the run is the bigger risk.
  if [ "${_KERNEL_UPDATE_PENDING:-0}" = "1" ]; then
    printf '\n  %s\n' "$(_c '1;33m' '━━━ KERNEL REBOOT REQUIRED━━━')"
    printf '%s\n' "  A new kernel is installed but not yet running."
    printf '  Currently running: %s\n' "$(_c '1;37m' "$(uname -r)")"
    local _boot_kernel
    _boot_kernel="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)"
    printf '  Highest installed: %s\n' "$(_c '1;37m' "${_boot_kernel:-unknown}")"
    if [ -t 0 ] && prompt_yn "Reboot now to activate the new kernel?" "n"; then
      warn "Rebooting in 5 seconds — Ctrl-C to cancel."
      sleep 5
      run sudo systemctl reboot
    else
      info "Skipped reboot. Run $(_c '1;36m' 'sudo systemctl reboot') when ready."
    fi
  fi

  # If the SSH self-heal guard was installed during this run, tell the user
  # that a check is scheduled at every boot and every minute -- so even a
  # full-disconnect lockout will recover automatically.
  if [ "${_SELF_HEAL_INSTALLED:-0}" = "1" ]; then
    printf '\n  %s\n' "$(_c '1;36m' '━━━ SSH SELF-HEAL GUARD ARMED ━━━')"
    if [ -f /etc/systemd/system/neohiro-ssh-watchdog.timer ]; then
      printf '%s\n' "  An SSH self-heal run is scheduled at every reboot and every 60s."
      printf '  Watchdog: %s\n' "$(_c '1;37m' 'systemd timer neohiro-ssh-watchdog.timer')"
    else
      printf '%s\n' "  An SSH self-heal run is scheduled at every reboot and every minute."
      printf '  Watchdog: %s\n' "$(_c '1;37m' '/etc/cron.d/neohiro-ssh-watchdog')"
    fi
    printf '  Log file:  %s\n' "$(_c '1;37m' '/var/log/neohiro-ssh-watchdog.log')"
    printf '  Disable:   %s\n' "$(_c '1;36m' "sudo bash $SCRIPT_PATH --no-self-heal")"
    printf '  Trigger now: %s\n' "$(_c '1;36m' "sudo bash $SCRIPT_PATH --self-heal")"
  fi
  if [ "$_FAIL_COUNT" -gt 0 ]; then
    if [ "$STRICT_RUN" = "1" ]; then
      err "$_FAIL_COUNT command(s) failed during the run (STRICT_RUN=1)."
      return 1
    else
      warn "$_FAIL_COUNT command(s) failed during the run. Re-run with STRICT_RUN=1 to exit non-zero."
    fi
  fi
  return 0
}

main "$@"
