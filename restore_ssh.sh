#!/usr/bin/env bash
# restore_ssh.sh - Diagnose and fix the most common SSH lockout causes.
#
# Works on: Ubuntu / Debian (apt), RHEL / AlmaLinux / Rocky / Fedora (dnf/yum),
#           SUSE / openSUSE (zypper), Arch Linux (pacman)
#
# Scans: sshd service, firewall rules (UFW or firewalld), PasswordAuthentication
# in both /etc/ssh/sshd_config AND /etc/ssh/sshd_config.d/*.conf drop-ins,
# authorized_keys, and the rollback log. Proposes each fix; asks before applying.
#
# Usage:   sudo bash restore_ssh.sh
#
# Exit codes: 0 = OK / fixes applied, 1 = could not apply, 2 = no fixes needed.
set -eo pipefail

PROG_NAME="restore_ssh"
ROLLBACK_LOG="/var/log/linux-install-rollback.log"

# Color constants sourced from lib/color.sh (falls back inline).
# shellcheck disable=SC1091
if [ -r "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/color.sh" ]; then
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/color.sh"
fi

# --- print helpers (format preserved from original restore_ssh.sh) ---
# If lib/color.sh was sourced, C_* constants are already set by _c's output;
# re-emit them so that print helpers produce the original "[ OK ]" format.
if [ -z "${C_RED:-}" ]; then
  if [ "$USE_COLOR" = "1" ]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_CYA=$'\033[1;36m'; C_BLD=$'\033[1;37m'; C_RST=$'\033[0m'
  else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_BLD=""; C_RST=""
  fi
fi
ok()    { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*" 1>&2; }
err()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" 1>&2; }
info()  { printf '%s[INFO]%s %s\n' "$C_CYA" "$C_RST" "$*"; }
bold()  { printf '%s%s%s\n' "$C_BLD" "$*" "$C_RST"; }

prompt_yn() {
  local q="$1" def="${2:-n}" ans
  printf '%s [y/n, default=%s]: ' "$q" "$def"
  read -r ans
  ans="${ans:-$def}"
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

run() {
  printf '  $ %s\n' "$*"
  "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    err "Command exited with code $rc: $*"
    return $rc
  fi
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    err "Please run as root: sudo bash $PROG_NAME"
    exit 1
  fi
}

# Detect package manager
detect_pkg_mgr() {
  if command -v pacman >/dev/null 2>&1 && [ -f /etc/pacman.conf ]; then
    echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v apt-get >/dev/null 2>&1 || [ -f /etc/apt/sources.list ]; then
    echo "apt"
  else
    echo ""
  fi
}

PKG_MGR=$(detect_pkg_mgr)

pkg_install_ssh() {
  case "$PKG_MGR" in
    apt)    run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server ;;
    dnf)    run sudo dnf install -y openssh-server ;;
    yum)    run sudo yum install -y openssh-server ;;
    zypper) run sudo zypper install -y --no-confirm openssh ;;
    pacman) run sudo pacman -S --noconfirm openssh ;;
    *)      err "Cannot install openssh-server: unsupported package manager ($PKG_MGR)"
             return 1 ;;
  esac
}

# Replace directive in-place or append it (used for both main config and drop-ins).
_set_or_append() {
  local file="$1" key="$2" value="$3"
  if [ ! -f "$file" ]; then
    echo "${key} ${value}" | sudo tee -a "$file" >/dev/null
    return
  fi
  if sudo grep -qE "^[[:space:]]*${key}[[:space:]]" "$file"; then
    sudo sed -i -E "s|^[[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$file"
  else
    echo "${key} ${value}" | sudo tee -a "$file" >/dev/null
  fi
}

# Check whether a directive has value X anywhere in a file (incl. drop-ins).
_has_value_in() {
  local pat="$1"; shift
  for f in "$@"; do
    [ -f "$f" ] || continue
    sudo grep -qE "$pat" "$f" && return 0
  done
  return 1
}

# Get the value of the first matching Port directive.
_effective_port() {
  awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' "$1" 2>/dev/null
}

ssh_port() { _effective_port /etc/ssh/sshd_config; }

count_pubkeys() {
  local f c total=0
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    c=$(sudo grep -cE '^(ssh-|ecdsa-)' "$f" 2>/dev/null) || c=0
    total=$((total + c))
  done
  echo "$total"
}

# Detect which sshd service unit is active on this distro.
_sshd_unit() {
  for u in sshd ssh; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      echo "$u"; return 0
    fi
  done
  echo "sshd"; return 1
}

restart_sshd() {
  local unit
  unit=$(_sshd_unit)
  run sudo systemctl restart "$unit"
}

diagnose() {
  bold "=== Diagnosing SSH lockout causes ==="
  FIXES=()  # global

  if ! command -v sshd >/dev/null 2>&1; then
    err "sshd is not installed. Run:  sudo bash restore_ssh.sh  (script will fix this)"
    FIXES+=("install-sshd")
  else
    ok "sshd is installed."
  fi

  local SSHCFG="/etc/ssh/sshd_config"
  if [ -f "$SSHCFG" ]; then
    ok "sshd config: $SSHCFG exists."
  else
    err "sshd config missing at $SSHCFG"
    FIXES+=("install-sshd")
  fi

  # 1) Service running?
  local ssh_unit
  ssh_unit=$(_sshd_unit 2>/dev/null) || ssh_unit="sshd"
  if systemctl is-active --quiet "$ssh_unit" 2>/dev/null; then
    ok "sshd service ($ssh_unit) is running."
  else
    FIXES+=("restart-ssh")
    warn "sshd service is NOT running."
  fi

  # 2) Firewall blocks the port?
  local port
  port=$(ssh_port 2>/dev/null) || port=""
  port="${port:-22}"

  if command -v firewall-cmd >/dev/null 2>&1 && \
     systemctl is-active --quiet firewalld 2>/dev/null; then
    if sudo firewall-cmd --list-ports 2>/dev/null | grep -qE "${port}/tcp"; then
      ok "firewalld allows port $port/tcp."
    else
      FIXES+=("fw-allow")
      warn "firewalld does not allow port $port/tcp."
    fi
  elif command -v ufw >/dev/null 2>&1 && \
       sudo ufw status 2>/dev/null | grep -qE 'Status: active'; then
    if sudo ufw status 2>/dev/null | grep -qE "ALLOW IN.*${port}/tcp"; then
      ok "UFW allows port $port/tcp."
    else
      FIXES+=("fw-allow")
      warn "UFW does not allow port $port/tcp."
    fi
  else
    info "No active firewalld or UFW detected; skipping firewall check."
  fi

  # 3) PasswordAuthentication no without a pubkey?
  local pa_disabled=0
  if [ -f "$SSHCFG" ] && sudo grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$SSHCFG"; then
    pa_disabled=1
  fi
  for d in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$d" ] || continue
    if sudo grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$d"; then
      pa_disabled=1
      warn "Drop-in $d disables PasswordAuthentication."
    fi
  done

  if [ "$pa_disabled" = "1" ]; then
    local pks
    pks=$(count_pubkeys)
    if [ "$pks" -eq 0 ]; then
      FIXES+=("reenable-password-auth")
      err "PasswordAuthentication=no AND no pubkeys are present (OpenSSH lockout)."
    else
      info "PasswordAuthentication=no but $pks pubkey(s) are present."
      info "Tailscale SSH still works regardless of this setting."
      if prompt_yn "Re-enable PasswordAuthentication anyway (fallback)?" "n"; then
        FIXES+=("reenable-password-auth")
      fi
    fi
  else
    ok "PasswordAuthentication is not disabled."
  fi

  # 4) Port non-default and not allow-listed?
  local eff_port
  eff_port=$(ssh_port 2>/dev/null)
  if [ -n "$eff_port" ] && [ "$eff_port" != "22" ]; then
    info "Effective SSH port: $eff_port (not 22)."
    info "If you reconnect from a host firewall, make sure $eff_port/tcp is open."
  fi

  # 5) AppArmor / SELinux denials? (informational)
  if command -v aa-status >/dev/null 2>&1; then
    if sudo aa-status 2>/dev/null | grep -qiE 'ssh.*enforce'; then
      info "AppArmor profile active for sshd (does not block Tailscale; uses sshd_config regardless)."
    fi
  fi

  # 6) Rollback log
  if [ -f "$ROLLBACK_LOG" ]; then
    info "Rollback log entries with 'ssh':"
    sudo grep -E 'ssh' "$ROLLBACK_LOG" 2>/dev/null | sed 's/^/    /' || true
  fi
}

apply_fixes() {
  if [ "${#FIXES[@]}" -eq 0 ]; then
    ok "No fixes required."
    return 2
  fi

  echo
  bold "=== Proposed fixes ==="
  local f
  for f in "${FIXES[@]}"; do
    case "$f" in
      install-sshd)            printf "  - Install openssh-server/openssh\n" ;;
      restart-ssh)              printf "  - Restart sshd service\n" ;;
      fw-allow)                 printf "  - Open SSH port in firewall\n" ;;
      reenable-password-auth)    printf "  - Re-enable PasswordAuthentication\n" ;;
    esac
  done

  if ! prompt_yn "Apply ALL proposed fixes now?" "y"; then
    info "No changes made. Run individual commands manually."
    return 1
  fi

  for f in "${FIXES[@]}"; do
    case "$f" in
      install-sshd)
        if ! pkg_install_ssh; then
          err "sshd installation failed."
          return 1
        fi
        ok "openssh-server installed."
        ;;
      restart-ssh)
        restart_sshd
        ok "sshd restarted."
        ;;
      fw-allow)
        local port
        port=$(ssh_port 2>/dev/null) || port="22"
        if command -v firewall-cmd >/dev/null 2>&1 && \
           systemctl is-active --quiet firewalld 2>/dev/null; then
          run sudo firewall-cmd --add-port="${port}/tcp" --permanent
          run sudo firewall-cmd --reload
          ok "firewalld: opened $port/tcp."
        elif command -v ufw >/dev/null 2>&1; then
          run sudo ufw allow "${port}/tcp"
          ok "UFW: opened $port/tcp."
        else
          warn "No firewall tool found; skipping."
        fi
        ;;
      reenable-password-auth)
        if [ -f /etc/ssh/sshd_config ]; then
          _set_or_append /etc/ssh/sshd_config "PasswordAuthentication" "yes"
        fi
        for d in /etc/ssh/sshd_config.d/*.conf; do
          [ -f "$d" ] || continue
          if sudo grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+no' "$d"; then
            run sudo sed -i -E \
              's|^[[:space:]]*PasswordAuthentication[[:space:]]+no|#PasswordAuthentication no  # disabled by restore_ssh.sh|' \
              "$d"
          fi
        done
        ok "PasswordAuthentication set to yes."
        ;;
    esac
  done

  local ssh_unit
  ssh_unit=$(_sshd_unit 2>/dev/null) || ssh_unit="sshd"
  if ! sudo sshd -t 2>&1; then
    err "sshd -t still fails. Check /var/log/auth.log for the exact error."
    return 1
  fi
  restart_sshd
  ok "sshd config valid; service restarted."
  return 0
}

main() {
  bold "neohiro/linux - Restore SSH (standalone)"
  require_root
  diagnose
  apply_fixes
}

FIXES=()
main "$@"
