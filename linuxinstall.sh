#!/bin/bash
#
# neohiro/linux  -  general interactive setup & hardening script
# Auto-detects Ubuntu / Debian / RHEL / AlmaLinux / Rocky / Fedora /
# CentOS / SUSE / openSUSE / Arch and adapts package manager, firewall,
# security tools, unattended upgrades, and kernel management accordingly.
# Automates the README tutorial with safety prompts.
# Run as root:   sudo bash linuxinstall.sh
#

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/neohiro/linux/main}"
TMP_DIR="$(mktemp -d)"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
ORIG_CWD="$(pwd)"
# _TMP_FILES tracks any per-function temp files so we can clean them on
# exit, even if the user hits Ctrl+C mid-step.
_TMP_FILES=()
trap 'rm -rf "$TMP_DIR" "${_TMP_FILES[@]}" 2>/dev/null' EXIT
# Track a temp file so it is removed on exit.  Use this instead of bare
# `mktemp` for any temp file that holds sensitive content (e.g. GPG output).
_tmpfile() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/linuxinstall.XXXXXX")
  _TMP_FILES+=("$f")
  printf '%s' "$f"
}

RECOVERY_CMD="tmux attach -t linux-setup   # reconnect after SSH disconnect"
ROLLBACK_LOG="${ROLLBACK_LOG:-/var/log/linux-install-rollback.log}"

# Ensure the rollback log exists and is writable before any backup is recorded.
# Creates it with 0600 mode (owner-only) to avoid leaking paths to other users.
_record_backup_init() {
  local logdir="${ROLLBACK_LOG%/*}"
  if [ "$EUID" -eq 0 ] && ! command -v sudo >/dev/null 2>&1; then
    # Running as root without sudo available: create log directly.
    mkdir -p "$logdir" 2>/dev/null || true
    touch "$ROLLBACK_LOG" 2>/dev/null || true
    chmod 0600 "$ROLLBACK_LOG" 2>/dev/null || true
  else
    sudo mkdir -p "$logdir" 2>/dev/null || true
    sudo touch "$ROLLBACK_LOG" 2>/dev/null || true
    sudo chmod 0600 "$ROLLBACK_LOG" 2>/dev/null || true
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

# Detect the active sshd service unit on this distro.
# Debian/Ubuntu use "ssh"; RHEL/Fedora/SUSE/Arch use "sshd". Returns 0 if a
# service is currently active, 1 otherwise. Caller must always default to
# "sshd" on a fresh system (no active service yet).
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

bold() { printf "%s\n" "$(_c '1m' "$*")"; }
warn() { printf "%s %s\n" "$(_c '1;33m' '[WARNING]')" "$*"; }
err()  { printf "%s %s\n" "$(_c '1;31m' '[ERROR]')"   "$*"; }
ok()   { printf "%s %s\n" "$(_c '1;32m' '[OK]')"      "$*"; }
info() { printf "  %s\n" "$*"; }

msg() { echo "=> $*"; }

# --- color gating: only emit ANSI when the terminal actually supports it ---
# Tailscale SSH and many remote PTYs report TERM=dumb, which renders
# CSI escapes as literal garbage. NO_COLOR is the XDG standard.
_USE_COLOR=1
case "${TERM:-}" in
  dumb|"") _USE_COLOR=0 ;;
esac
[ -n "${NO_COLOR:-}" ] && _USE_COLOR=0
# _c <color> <text> -- wrap in ANSI only if supported, else print plain.
_c() {
  if [ "$_USE_COLOR" = "1" ]; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

# STRICT_RUN=1 makes run() propagate the actual exit code (default is 0,
# so a single failed command does not abort the whole interactive run).
# Set this in CI / unattended deployments to detect partial-failure runs.
STRICT_RUN="${STRICT_RUN:-0}"
_FAIL_COUNT=0

run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf "  %s\n" "DRY: $*"; return 0
  fi
  msg "$*"
  "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    err "Command failed (exit $rc): $*"
    _FAIL_COUNT=$((_FAIL_COUNT + 1))
  fi
  if [ "$STRICT_RUN" = "1" ]; then
    return $rc
  fi
  return 0
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
    warn "stdin is not a TTY and /dev/tty is unavailable; defaulting to 1 for: $q"
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
  gpg_out=$(_tmpfile)
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
  [system_update]=pending
  [dnscrypt]=pending
  [firewall]=pending
  [tor]=pending
  [ssh_hardening]=pending
  [fail2ban]=pending
  [unattended]=pending
  [ipv6]=pending
  [sysctl]=pending
  [apparmor]=pending
  [pam]=pending
  [optimize_asr]=pending
  [deepclean]=pending
  [other_scripts]=pending
  [summary]=pending
)
CHECKLIST_LABEL_tmux_wrap="Auto-wrap SSH session in tmux"
CHECKLIST_LABEL_env_detect="Detect environment (desktop/server)"
CHECKLIST_LABEL_system_update="System update + base packages"
CHECKLIST_LABEL_dnscrypt="DNSCrypt + DNS routing"
CHECKLIST_LABEL_firewall="Firewall (UFW / firewalld)"
CHECKLIST_LABEL_tor="Tor daemon"
CHECKLIST_LABEL_ssh_hardening="SSH hardening (lockout-prone)"
CHECKLIST_LABEL_fail2ban="Fail2ban"
CHECKLIST_LABEL_unattended="Unattended security upgrades"
CHECKLIST_LABEL_ipv6="Disable IPv6"
CHECKLIST_LABEL_sysctl="Kernel/sysctl hardening"
CHECKLIST_LABEL_apparmor="AppArmor"
CHECKLIST_LABEL_pam="Password & lockout policy"
CHECKLIST_LABEL_optimize_asr="OptimizeLinuxASR.sh (ASR)"
CHECKLIST_LABEL_deepclean="DeepClean.sh (cleanup)"
CHECKLIST_LABEL_other_scripts="Other helpers (Shadowsocks / server extras)"
CHECKLIST_LABEL_summary="Print run summary"

mark_step() {
  CHECKLIST[$1]="${2:-done}"
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
show_progress() {
  local done=0 total=0 i key
  for key in tmux_wrap env_detect system_update dnscrypt firewall tor ssh_hardening fail2ban unattended ipv6 sysctl apparmor pam optimize_asr deepclean other_scripts summary; do
    total=$((total + 1))
    case "${CHECKLIST[$key]:-pending}" in
      done)   done=$((done + 1)) ;;
      running) done=$((done + 1)) ;;
      skip)   done=$((done + 1)) ;;
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
  for key in tmux_wrap env_detect system_update dnscrypt firewall tor ssh_hardening fail2ban unattended ipv6 sysctl apparmor pam optimize_asr deepclean other_scripts summary; do
    local status="${CHECKLIST[$key]:-pending}"
    local icon color
    case "$status" in
      done)    icon='[x]'; color='1;32m' ;;
      running) icon='[>]'; color='1;33m' ;;
      skip)    icon='[ ]'; color='1;30m' ;;
      *)       icon='[ ]'; color='1;30m' ;;
    esac
    local label_var="CHECKLIST_LABEL_${key}"
    printf '  '
    _c "$color" "$icon "
    printf '%s\n' "${!label_var}"
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
  if [ "$disk_delta" -gt 0 ]; then
    disk_freed_str="$(numfmt --to=iec-i --suffix=B "$(( disk_delta * 1024 ))" 2>/dev/null || echo "${disk_delta} KB freed")"
  else
    disk_freed_str="N/A (run as root to measure)"
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
  prompt_choice "Apply which set of categories?" \
    "Recommended (safe, no SSH-lockout risk)" \
    "Standard (includes SSH hardening, Fail2ban, sysctl, AppArmor)" \
    "Full (includes Tor, IPv6 disable, attack-surface reduction, deep clean)" \
    "Custom (I will be asked per category)" \
    "Maintenance suite (pick individual categories, return to this menu)"
  REPLY_PROFILE=$REPLY_CHOICE
}

ask_category_enabled() {
  local key="$1" desc="$2" default="$3"
  _should_run_step "$key" || return 1
  case "$REPLY_PROFILE" in
    0) [ "$default" = "y" ]; return $?;;
    1) [ "$default" = "y" ] || [ "$key" = "ssh" ] || [ "$key" = "fail2ban" ] || [ "$key" = "sysctl" ] || [ "$key" = "pam" ]; return $?;;
    2) return 0;;
    3) prompt_yn "Run: $desc?" "$default"; return $?;;
    4) return 1;;
  esac
}

maintenance_menu() {
  local choice rc
  while true; do
    prompt_choice "Maintenance suite — pick a category (15=exit)" \
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
       "Other helpers (reserved for future cross-distro helpers)" \
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
      13) info "No other helpers in the linux repo yet."; break;;
     14) info "Returning to main menu."; break;;
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
  _fw_detect
  fw_default_incoming_deny
  if [ "$USE_REMOTE_SSH" = "yes" ] || [ "$ENV_TYPE" = "server" ]; then
    warn "Allowing SSH (22) -- required for remote access."
    fw_allow "22/tcp"
    metrics_add fw_rules_added 1
  fi
  fw_enable
  metrics_add fw_rules_added 2
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
  local tor_backup
  if ! sudo systemctl is-active --quiet tor; then
    err "Primary tor failed - restoring torrc and aborting combined setup."
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

run sudo ufw allow "$OR_PORT"/tcp
run sudo ufw allow "$DIR_PORT"/tcp

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
run sudo ufw allow "$OR_PORT"/tcp 2>/dev/null || true
run sudo ufw allow "$DIR_PORT"/tcp 2>/dev/null || true
run sudo systemctl restart tor
  local tor_backup
  if ! sudo systemctl is-active --quiet tor; then
    err "tor failed - restoring torrc."
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
    info "Keeping IPv6 enabled."; return 0
  fi
  if ! prompt_yn "Type 'yes' to confirm you understand network breakage" "no"; then
    info "Aborted IPv6 disable."; return 0
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
  printf "\033[1;33m──────────────────────────────────────────────────────────────────────\033[0m"
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
    run sudo ufw allow 2222/tcp
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
  local ssh_unit
  ssh_unit=$(_sshd_unit)
  run sudo systemctl restart "$ssh_unit"
  ok "SSH hardened and restarted."
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
  metrics_add sysctls_applied 22
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

  # Full + server => run SSH hardening in auto mode (no interactive lockout-prone prompts)
  if [ "$REPLY_PROFILE" = "2" ] && [ "$ENV_TYPE" = "server" ]; then
    FULL_AUTO=1
    SSH_AUTO_MODE=1
    USE_REMOTE_SSH="yes"  # treat as remote because we're a headless server
  fi

  show_progress

  # Take a lightweight snapshot of /etc before any hardening so the entire
  # config tree can be restored wholesale.  Skipped if ENABLE_ETC_SNAPSHOT=0.
  _take_etc_snapshot

  if [ "$REPLY_PROFILE" = "4" ]; then
    maintenance_menu
    if [ "$USE_REMOTE_SSH" = "yes" ]; then
      info "Because SSH may have been changed, verify a SECOND session can log in BEFORE closing this one."
    fi
    _print_run_summary
    return $?
  fi

  ask_category_enabled "system"      "System update + base packages" "y"      && { mark_step system_update "running"; show_progress; update_system;  mark_step system_update "done"; update_kernel; }
  ask_category_enabled "dns"         "DNSCrypt (DNS method is ambiguous - you'll be asked)" "n" && { mark_step dnscrypt "running"; show_progress; setup_dnscrypt; mark_step dnscrypt "done"; }
  ask_category_enabled "firewall"    "Firewall (UFW)" "y"                      && { mark_step firewall "running"; show_progress; setup_firewall; mark_step firewall "done"; }
  ask_category_enabled "tor"         "Tor daemon" "n"                          && { mark_step tor "running"; show_progress; setup_tor; mark_step tor "done"; }
  ask_category_enabled "ssh"         "SSH hardening (lockout-prone)" "n"       && { mark_step ssh_hardening "running"; show_progress; harden_ssh; mark_step ssh_hardening "done"; }
  ask_category_enabled "fail2ban"    "Fail2ban" "n"                            && { mark_step fail2ban running; show_progress; setup_fail2ban; mark_step fail2ban done; }
  ask_category_enabled "unattended"  "Unattended security upgrades" "y"        && { mark_step unattended "running"; show_progress; configure_unattended_upgrades; mark_step unattended "done"; }
  ask_category_enabled "ipv6"        "Disable IPv6 (risky)" "n"                && { mark_step ipv6 running; show_progress; disable_ipv6; mark_step ipv6 done; }
  ask_category_enabled "sysctl"      "Kernel/sysctl hardening profile" "n"     && { mark_step sysctl "running"; show_progress; harden_sysctl; mark_step sysctl "done"; }
  ask_category_enabled "apparmor"    "AppArmor" "n"                            && { mark_step apparmor "running"; show_progress; setup_apparmor; mark_step apparmor "done"; }
  ask_category_enabled "pam"         "Password & lockout policy" "n"           && { mark_step pam "running"; show_progress; harden_passwords; mark_step pam "done"; }
  ask_category_enabled "optimize"    "Run OptimizeLinuxASR.sh (new helper)" "n" && { mark_step optimize_asr "running"; show_progress; run_optimize_asr; mark_step optimize_asr "done"; }
  ask_category_enabled "deepclean"   "Run DeepClean.sh (new helper)" "n"       && { mark_step deepclean "running"; show_progress; run_deepclean; mark_step deepclean "done"; }

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
  bold "Done."
  mark_step summary "running"
  show_progress
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
    printf '\n  \033[1;33m━━━ KERNEL REBOOT REQUIRED\033[0m\n'
    printf '%s\n' "  A new kernel is installed but not yet running."
    printf '  Currently running: \033[1;37m%s\033[0m\n' "$(uname -r)"
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
