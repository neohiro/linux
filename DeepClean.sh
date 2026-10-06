#!/bin/bash
# Comprehensive Linux DeepClean & Auto-Prune Script
# Works on: Ubuntu / Debian (apt), RHEL / AlmaLinux / Rocky / Fedora (dnf/yum),
#           SUSE / openSUSE (zypper), Arch Linux (pacman)
# Run as root:  sudo ./DeepClean.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[!] This script must be run as root. Please use sudo." >&2
  exit 1
fi

# Color helpers from lib/color.sh (falls back inline).
# shellcheck disable=SC1091
if [ -r "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/color.sh" ]; then
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/color.sh"
fi

# Repository transport guard. DeepClean's apt branch runs
# `apt-get autoremove --purge`, which resolves dependency chains and can
# pull packages from a mirror, so HTTPS is enforced before it.
# shellcheck disable=SC1091
if [ -r "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/apt-https.sh" ]; then
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/apt-https.sh"
fi

# If lib/color.sh was not sourced or did not set USE_COLOR, run the canonical
# gate inline so _c is safe to call in all execution paths.
if [ -z "${USE_COLOR:-}" ]; then
  if [ "${NEOHIRO_COLOR:-}" = "1" ]; then
    USE_COLOR=1
  elif [ "${NEOHIRO_COLOR:-}" = "0" ] || { [ -n "${NO_COLOR:-}" ] && [ "${NO_COLOR:-}" != "0" ]; } || [ "${TERM:-}" = "dumb" ]; then
    USE_COLOR=0
  elif { [ "${FORCE_TTY:-}" != "1" ] && [ ! -t 1 ]; } || ! command -v tput >/dev/null 2>&1; then
    USE_COLOR=0
  else
    _tcol=$(tput colors 2>/dev/null) || _tcol=""
    case "${_tcol}" in
      ''|*[!0-9]*) USE_COLOR=0 ;;
      *) [ "${_tcol}" -ge 8 ] && USE_COLOR=1 || USE_COLOR=0 ;;
    esac
  fi
fi

# _c <ansi-code> <text> -- wrap text in CSI escapes iff USE_COLOR=1.
_c() { if [ "$USE_COLOR" = "1" ]; then printf '\033[%s%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

# Print helpers. All accept a single message string. warn/err go to stderr.
msg()  { printf '%s\n' "$(_c '1;36m' '[*]' "$*")"; }
ok()   { printf '%s\n' "$(_c '1;32m' '[+]' "$*")"; }
warn() { printf '%s\n' "$(_c '1;33m' '[!]' "$*")"; }
err()  { printf '%s\n' "$(_c '1;31m' '[!]' "$*")" >&2; }

pkg_mgr() {
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

PM=$(pkg_mgr)

# Capture disk usage before cleaning (with validation)
df_output=$(df -kP / 2>/dev/null | tail -1) || df_output=""
if [ -n "$df_output" ]; then
    USED_BEFORE_KB=$(echo "$df_output" | awk '{print $3}')
    # Validate it's a number
    case "$USED_BEFORE_KB" in
        ''|*[!0-9]*) USED_BEFORE_KB=0 ;;
    esac
else
    USED_BEFORE_KB=0
fi

# Capture storage breakdown BEFORE any cleaning (for accurate before/after comparison)
msg "Analyzing storage breakdown (pre-clean)..."
BREAKDOWN_BEFORE_FILE=$(analyze_storage_breakdown "/") || BREAKDOWN_BEFORE_FILE=""
# Read before values immediately
declare -A BEFORE_KB
if [ -n "$BREAKDOWN_BEFORE_FILE" ] && [ -f "$BREAKDOWN_BEFORE_FILE" ]; then
    while read -r cat kb; do
        case "$kb" in
            ''|*[!0-9]*) kb=0 ;;
        esac
        BEFORE_KB["$cat"]="${kb:-0}"
    done < "$BREAKDOWN_BEFORE_FILE"
fi
# Compute "other" as residual (with defaults for missing categories)
TOTAL_USED_BEFORE_KB=${USED_BEFORE_KB:-0}
SUM_CATS_BEFORE=0
for cat in system user logs cache containers; do
    SUM_CATS_BEFORE=$((SUM_CATS_BEFORE + ${BEFORE_KB[$cat]:-0}))
done
BEFORE_KB["other"]=$((TOTAL_USED_BEFORE_KB - SUM_CATS_BEFORE))
[ "${BEFORE_KB[other]}" -lt 0 ] && BEFORE_KB["other"]=0
# Cleanup
[ -n "$BREAKDOWN_BEFORE_FILE" ] && rm -f "$BREAKDOWN_BEFORE_FILE"

msg "Detected package manager: ${PM:-none}"

# Precaution: `apt-get autoremove --purge` below resolves dependencies and
# can fetch from a mirror, so force repository traffic over HTTPS first.
# No-op once per process, and a silent no-op when the lib is unavailable
# (curl|bash of DeepClean.sh on its own).
if declare -F apt_https_guard >/dev/null 2>&1 && [ "$PM" = "apt" ]; then
  apt_https_guard "DeepClean" || true
elif [ "$PM" = "apt" ]; then
  # Reached when this file is curl|bash'd on its own, with no lib/ next to
  # it. Say so rather than silently skipping the precaution.
  echo "[!] lib/apt-https.sh not found next to this script; skipping the" >&2
  echo "[!] repository transport guard before 'apt-get autoremove --purge'." >&2
fi

msg "Starting DeepClean..."

# ── Log Size Audit (Pre-Clean) ────────────────────────────────────────
msg "Auditing current log sizes..."
TOTAL_LOG_KB=0
for log_path in /var/log/journal /var/log; do
    if [ -d "$log_path" ]; then
        size_kb=$(du -sk "$log_path" 2>/dev/null | awk '{print $1}')
        [ -n "$size_kb" ] && TOTAL_LOG_KB=$((TOTAL_LOG_KB + size_kb))
    fi
done
msg "Current log footprint: ${TOTAL_LOG_KB} KB"

# 1. Systemd Journal Logs — enforce 1MB cap
msg "Cleaning systemd journal logs (target: 1MB max)..."
journalctl --vacuum-time=1d  2>/dev/null || true
journalctl --vacuum-size=1M  2>/dev/null || true

# 2. Rotated and Compressed Logs — remove all rotated archives
msg "Removing old rotated log files in /var/log..."
find /var/log -type f -regex ".*\.[0-9]$" -delete 2>/dev/null || true
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.xz" -delete 2>/dev/null || true

# 3. Active Legacy Logs — truncate to 1MB if larger, else leave alone
msg "Truncating active legacy log files larger than 1MB..."
for log in /var/log/syslog /var/log/messages /var/log/auth.log \
           /var/log/kern.log /var/log/dpkg.log /var/log/daemon.log \
           /var/log/ufw.log /var/log/fail2ban.log /var/log/apt/history.log \
           /var/log/apt/term.log /var/log/pacman.log /var/log/zypper.log \
           /var/log/dnf.log /var/log/yum.log; do
    if [ -f "$log" ] && [ -w "$log" ]; then
        # Portable stat: GNU stat uses -c%s, BSD/macOS uses -f%z
        size_bytes=0
        if stat -c%s "$log" >/dev/null 2>&1; then
            size_bytes=$(stat -c%s "$log" 2>/dev/null || echo 0)
        elif stat -f%z "$log" >/dev/null 2>&1; then
            size_bytes=$(stat -f%z "$log" 2>/dev/null || echo 0)
        fi
        size_kb=$((size_bytes / 1024))
        if [ "${size_kb:-0}" -gt 1024 ]; then
            truncate -s 1M "$log" 2>/dev/null || true
            msg "  Truncated $log (${size_kb}KB -> 1MB)"
        fi
    fi
done

# 4. Package Manager Cache & Orphans
msg "Cleaning package manager cache and orphaned packages..."
case "$PM" in
  apt)
    apt-get clean -y
    apt-get autoremove --purge -y
    dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge 2>/dev/null || true
    ;;
  dnf)
    dnf clean all
    dnf autoremove -y
    ;;
  yum)
    yum clean all
    yum autoremove -y
    ;;
  zypper)
    zypper clean --all
    zypper packages --unneeded --delete --no-confirm 2>/dev/null || true
    ;;
  pacman)
    pacman -Scc --noconfirm
    pacman -Qdtq | xargs -r pacman -Rns --noconfirm
    ;;
  *)
    warn "No supported package manager found; skipping cache cleanup."
    ;;
esac

# 5. Snap Revisions (not Ubuntu-only; snap exists on other distros too)
if command -v snap >/dev/null 2>&1; then
    msg "Removing disabled snap revisions..."
    { LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' |
        while read -r snapname revision; do
            snap remove "$snapname" --revision="$revision" 2>/dev/null || true
        done; } || true
    rm -rf /var/lib/snapd/cache/* 2>/dev/null || true
fi

# 6. Docker Artifacts
if command -v docker >/dev/null 2>&1; then
    msg "Deep cleaning Docker artifacts..."
    docker system prune -a -f --volumes 2>/dev/null || true
fi

# 7. Flatpak Leftovers
if command -v flatpak >/dev/null 2>&1; then
    msg "Removing unused Flatpak runtimes..."
    flatpak uninstall --unused -y 2>/dev/null || true
fi

# 8. Crash Reports & System Trash
msg "Removing old crash reports and system trash..."
rm -rf /var/crash/* 2>/dev/null || true
systemd-tmpfiles --clean 2>/dev/null || true
rm -rf /root/.local/share/Trash/* 2>/dev/null || true
find /home/*/.local/share/Trash/* -delete 2>/dev/null || true

# ── Auto-Pruning Config ──────────────────────────────────────────────

# 9. journald retention — enforce 1MB total cap (persistent, reboot-proof)
msg "Configuring journald for 1MB max retention (reboot-proof, hardened)..."
JOURNALD_CONF="/etc/systemd/journald.conf"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/99-neohiro-1mb.conf"
mkdir -p /etc/systemd/journald.conf.d

# Determine storage mode: persistent if /var/log/journal exists, else volatile
if [ -d /var/log/journal ] && [ -w /var/log/journal ]; then
    STORAGE_MODE="persistent"
    RUNTIME_MAX_USE="1M"
    RUNTIME_MAX_FILE_SIZE="1M"
    RUNTIME_MAX_RETENTION_SEC="1day"
else
    STORAGE_MODE="volatile"
    RUNTIME_MAX_USE="1M"
    RUNTIME_MAX_FILE_SIZE="1M"
    RUNTIME_MAX_RETENTION_SEC="1day"
fi

# Write drop-in atomically (staging + rename) — this is the source of truth
cat > "${JOURNALD_DROPIN}.tmp" <<JOURNALDROPIN
[Journal]
# Enforced by neohiro/linux DeepClean — 1MB max journal size, hardened
Storage=${STORAGE_MODE}
SystemMaxUse=1M
SystemMaxFileSize=1M
SystemMaxFiles=2
MaxRetentionSec=1day
MaxFileSec=1day
RuntimeMaxUse=${RUNTIME_MAX_USE}
RuntimeMaxFileSize=${RUNTIME_MAX_FILE_SIZE}
RuntimeMaxFiles=2
RuntimeMaxRetentionSec=${RUNTIME_MAX_RETENTION_SEC}
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
MaxLevelStore=warning
MaxLevelSyslog=warning
MaxLevelKMsg=warning
MaxLevelConsole=warning
MaxLevelWall=emerg
Compress=yes
SyncIntervalSec=30
RateLimitIntervalSec=30s
RateLimitBurst=500
Audit=no
Seal=yes
SplitMode=none
JOURNALDROPIN
mv "${JOURNALD_DROPIN}.tmp" "$JOURNALD_DROPIN"

# Also update main config for immediate effect (single pass, atomic)
{
    grep -vE '^(#?)(Storage|SystemMaxUse|SystemMaxFileSize|SystemMaxFiles|MaxRetentionSec|MaxFileSec|RuntimeMaxUse|RuntimeMaxFileSize|RuntimeMaxFiles|RuntimeMaxRetentionSec|ForwardToSyslog|ForwardToKMsg|ForwardToConsole|ForwardToWall|MaxLevelStore|MaxLevelSyslog|MaxLevelKMsg|MaxLevelConsole|MaxLevelWall|Compress|SyncIntervalSec|RateLimitIntervalSec|RateLimitBurst|Audit|Seal|SplitMode)=' "$JOURNALD_CONF" 2>/dev/null || true
    cat <<EOF
Storage=${STORAGE_MODE}
SystemMaxUse=1M
SystemMaxFileSize=1M
SystemMaxFiles=2
MaxRetentionSec=1day
MaxFileSec=1day
RuntimeMaxUse=${RUNTIME_MAX_USE}
RuntimeMaxFileSize=${RUNTIME_MAX_FILE_SIZE}
RuntimeMaxFiles=2
RuntimeMaxRetentionSec=${RUNTIME_MAX_RETENTION_SEC}
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
MaxLevelStore=warning
MaxLevelSyslog=warning
MaxLevelKMsg=warning
MaxLevelConsole=warning
MaxLevelWall=emerg
Compress=yes
SyncIntervalSec=30
RateLimitIntervalSec=30s
RateLimitBurst=500
Audit=no
Seal=yes
SplitMode=none
EOF
} > "${JOURNALD_CONF}.tmp" && mv "${JOURNALD_CONF}.tmp" "$JOURNALD_CONF"

# If volatile storage, remove persistent journal directory to free space
if [ "${STORAGE_MODE}" = "volatile" ] && [ -d /var/log/journal ]; then
    msg "  Volatile storage mode: removing /var/log/journal..."
    rm -rf /var/log/journal 2>/dev/null || true
fi

# Vacuum on boot via systemd-tmpfiles
mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/99-neohiro-journald-vacuum.conf <<'TMPFILESEOF'
# Vacuum journald on boot to enforce 1MB limit immediately
R /var/log/journal 0755 root systemd-journal -
R /run/log/journal 0755 root systemd-journal -
TMPFILESEOF

systemctl reload systemd-journald 2>/dev/null || systemctl restart systemd-journald 2>/dev/null
msg "  journald configured: ${STORAGE_MODE}, 1MB total/1MB file, 1-day retention, hardened (no audit, sealed, split=none, rate-limit=500)"

# 10. Package-manager auto-clean config
case "$PM" in
  apt)
    msg "Configuring apt auto-clean..."
    cat > /etc/apt/apt.conf.d/99-auto-clean <<'APTEOF'
APT::Keep-Downloaded-Packages "false";
APT::Get::AutomaticRemove "true";
APT::Get::Purge "true";
APTEOF
    ;;
  dnf)
    msg "Configuring dnf auto-clean..."
    mkdir -p /etc/dnf/dnf.conf.d/
    grep -q "^keepcache" /etc/dnf/dnf.conf 2>/dev/null && \
        sed -i 's/^keepcache=.*/keepcache=0/' /etc/dnf/dnf.conf || \
        echo "keepcache=0" >> /etc/dnf/dnf.conf
    ;;
  yum)
    msg "Configuring yum auto-clean..."
    grep -q "^keepcache" /etc/yum.conf 2>/dev/null && \
        sed -i 's/^keepcache=.*/keepcache=0/' /etc/yum.conf || \
        echo "keepcache=0" >> /etc/yum.conf
    ;;
  zypper)
    msg "Configuring zypper auto-clean..."
    sed -i 's/^solver.onlyRequires.*/solver.onlyRequires = true/' /etc/zypp/zypp.conf 2>/dev/null || true
    ;;
  pacman)
    msg "Pacman cache managed by /etc/pacman.d/hooks/clean.hook (create if needed)..."
    ;;
  *)
    ;;
esac

# 11. systemd-coredump limits — 1MB cap
msg "Configuring systemd-coredump limits (1MB max)..."
COREDUMP_CONF="/etc/systemd/coredump.conf"
COREDUMP_DROPIN="/etc/systemd/coredump.conf.d/99-neohiro-1mb.conf"
mkdir -p /etc/systemd/coredump.conf.d

# Write drop-in atomically
cat > "${COREDUMP_DROPIN}.tmp" <<'COREDUMPDROPIN'
[Coredump]
# Enforced by neohiro/linux DeepClean — 1MB max coredump size
MaxUse=1M
ExternalSizeMax=1M
Compress=yes
ProcessSizeMax=1M
COREDUMPDROPIN
mv "${COREDUMP_DROPIN}.tmp" "$COREDUMP_DROPIN"

# Update main config atomically (single pass)
{
    grep -vE '^(#?)(MaxUse|ExternalSizeMax|Compress|ProcessSizeMax)=' "$COREDUMP_CONF" 2>/dev/null || true
    cat <<'EOF'
MaxUse=1M
ExternalSizeMax=1M
Compress=yes
ProcessSizeMax=1M
EOF
} > "${COREDUMP_CONF}.tmp" && mv "${COREDUMP_CONF}.tmp" "$COREDUMP_CONF"

systemctl reload systemd-coredump.socket 2>/dev/null || systemctl restart systemd-coredump.socket 2>/dev/null
msg "  coredump configured: 1MB total, 1MB per dump"

# 12. logrotate defaults — 1MB per file, 1 rotation, daily
msg "Configuring global logrotate for 1MB max per log file (reboot-proof)..."
LOGROTATE_CONF="/etc/logrotate.conf"
if [ -f "$LOGROTATE_CONF" ]; then
    # Single-pass atomic rewrite: strip old keys, append new ones
    {
        grep -vE '^(#?)(compress|delaycompress|rotate|size|daily|weekly|monthly|yearly|create|notifempty)' "$LOGROTATE_CONF" 2>/dev/null || true
        cat <<'EOF'
compress
delaycompress
rotate 1
size 1M
daily
create 0640 root adm
notifempty
EOF
    } > "${LOGROTATE_CONF}.tmp" && mv "${LOGROTATE_CONF}.tmp" "$LOGROTATE_CONF"
else
    # Create minimal config if missing
    cat > "$LOGROTATE_CONF" <<'EOF'
compress
delaycompress
rotate 1
size 1M
daily
create 0640 root adm
notifempty
EOF
fi

# 13. Create per-service logrotate drop-ins for 1MB enforcement
msg "Installing per-service logrotate drop-ins (1MB max)..."
mkdir -p /etc/logrotate.d

# Helper: atomic write to logrotate.d
_write_logrotate() {
    local file="$1" content="$2"
    cat > "${file}.tmp" <<EOF
$content
EOF
    mv "${file}.tmp" "$file"
}

# System logs
_write_logrotate /etc/logrotate.d/99-neohiro-syslog "$(cat <<'SYSLOGROTATE'
/var/log/syslog
/var/log/messages
/var/log/auth.log
/var/log/kern.log
/var/log/daemon.log
/var/log/user.log
/var/log/ufw.log
{
    daily
    size 1M
    rotate 1
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || systemctl reload rsyslog 2>/dev/null || true
    endscript
}
SYSLOGROTATE
)"

# Package manager logs
_write_logrotate /etc/logrotate.d/99-neohiro-pkg "$(cat <<'PKGROTATE'
/var/log/dpkg.log
/var/log/apt/history.log
/var/log/apt/term.log
/var/log/pacman.log
/var/log/zypper.log
/var/log/dnf.log
/var/log/yum.log
/var/log/aptitude
{
    daily
    size 1M
    rotate 1
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
PKGROTATE
)"

# Fail2ban
if [ -f /etc/fail2ban/fail2ban.conf ] || systemctl list-unit-files fail2ban.service >/dev/null 2>&1; then
_write_logrotate /etc/logrotate.d/99-neohiro-fail2ban "$(cat <<'F2BROTATE'
/var/log/fail2ban.log
{
    daily
    size 1M
    rotate 1
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    postrotate
        systemctl reload fail2ban 2>/dev/null || fail2ban-client reload 2>/dev/null || true
    endscript
}
F2BROTATE
)"
fi

# SSH
_write_logrotate /etc/logrotate.d/99-neohiro-ssh "$(cat <<'SSHROTATE'
/var/log/sshd.log
/var/log/ssh.log
{
    daily
    size 1M
    rotate 1
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
SSHROTATE
)"

# 14. Docker log driver — 1MB max per container log
if command -v docker >/dev/null 2>&1; then
    msg "Configuring Docker log driver for 1MB max per container..."
    mkdir -p /etc/docker
    DOCKER_CFG="/etc/docker/daemon.json"
    if [ -f "$DOCKER_CFG" ]; then
        # Merge with existing config using jq if available
        if command -v jq >/dev/null 2>&1; then
            jq '. + {"log-driver": "json-file", "log-opts": {"max-size": "1m", "max-file": "1"}}' "$DOCKER_CFG" > "${DOCKER_CFG}.tmp" && mv "${DOCKER_CFG}.tmp" "$DOCKER_CFG"
        else
            # Fallback: use python3 for proper JSON merge (more reliable than sed)
            if command -v python3 >/dev/null 2>&1; then
                python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError:
        cfg = {}
cfg.setdefault("log-driver", "json-file")
cfg.setdefault("log-opts", {})
cfg["log-opts"]["max-size"] = "1m"
cfg["log-opts"]["max-file"] = "1"
with open(sys.argv[1] + ".tmp", "w") as f:
    json.dump(cfg, f, indent=2)
' "$DOCKER_CFG" && mv "${DOCKER_CFG}.tmp" "$DOCKER_CFG"
            else
                # Last resort: replace entire file (backup first)
                cp "$DOCKER_CFG" "${DOCKER_CFG}.bak" 2>/dev/null || true
                cat > "${DOCKER_CFG}.tmp" <<'DOCKERD'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "1m",
    "max-file": "1"
  }
}
DOCKERD
                mv "${DOCKER_CFG}.tmp" "$DOCKER_CFG"
            fi
        fi
    else
        cat > "${DOCKER_CFG}.tmp" <<'DOCKERD'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "1m",
    "max-file": "1"
  }
}
DOCKERD
        mv "${DOCKER_CFG}.tmp" "$DOCKER_CFG"
    fi
    systemctl reload docker 2>/dev/null || systemctl restart docker 2>/dev/null
    msg "  Docker configured: json-file, 1MB max size, 1 file per container"
fi

# 15. Containerd / CRI-O log limits (Kubernetes)
if command -v containerd >/dev/null 2>&1 || [ -f /etc/containerd/config.toml ]; then
    msg "Configuring containerd log limits (1MB)..."
    mkdir -p /etc/containerd
    CONTAINERD_CFG="/etc/containerd/config.toml"
    if [ -f "$CONTAINERD_CFG" ]; then
        # Use awk for robust section-aware update
        awk '
            BEGIN { in_cri=0; seen_size=0; seen_files=0; has_cri=0 }
            /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\]/ { in_cri=1; has_cri=1 }
            in_cri && /^containerd_max_log_size/ { print "  container_max_log_size = 1048576"; seen_size=1; next }
            in_cri && /^containerd_max_log_files/ { print "  container_max_log_files = 1"; seen_files=1; next }
            in_cri && /^\[/ && !/^\[plugins\."io\.containerd\.grpc\.v1\.cri"\]/ { in_cri=0 }
            { print }
            END {
                if (has_cri) {
                    if (in_cri && !seen_size) print "  container_max_log_size = 1048576"
                    if (in_cri && !seen_files) print "  container_max_log_files = 1"
                } else {
                    # CRI section not found - append it
                    print ""
                    print "[plugins.\"io.containerd.grpc.v1.cri\"]"
                    print "  container_max_log_size = 1048576"
                    print "  container_max_log_files = 1"
                }
            }
        ' "$CONTAINERD_CFG" > "${CONTAINERD_CFG}.tmp" && mv "${CONTAINERD_CFG}.tmp" "$CONTAINERD_CFG"
    else
        cat > "${CONTAINERD_CFG}.tmp" <<'CONTAINERDLOG'
version = 2
[plugins."io.containerd.grpc.v1.cri"]
  container_max_log_size = 1048576  # 1MB
  container_max_log_files = 1
CONTAINERDLOG
        mv "${CONTAINERD_CFG}.tmp" "$CONTAINERD_CFG"
    fi
    systemctl reload containerd 2>/dev/null || systemctl restart containerd 2>/dev/null
fi

# 16. kubelet log limits (if Kubernetes node)
if command -v kubelet >/dev/null 2>&1; then
    msg "Configuring kubelet log limits (1MB)..."
    mkdir -p /etc/systemd/system/kubelet.service.d
    KUBELET_DROPIN="/etc/systemd/system/kubelet.service.d/99-neohiro-log-limit.conf"
    cat > "${KUBELET_DROPIN}.tmp" <<'KUBELETLOG'
[Service]
Environment="KUBELET_LOG_ARGS=--container-log-max-files=1 --container-log-max-size=1Mi"
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_LOG_ARGS $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBELET_ARGS $KUBELET_EXTRA_ARGS
KUBELETLOG
    mv "${KUBELET_DROPIN}.tmp" "$KUBELET_DROPIN"
    systemctl daemon-reload
    systemctl reload kubelet 2>/dev/null || systemctl restart kubelet 2>/dev/null
fi

# 17. rsyslog / syslog-ng rate limiting (prevent log floods)
msg "Configuring syslog rate limiting (prevent floods)..."
if [ -f /etc/rsyslog.conf ] || command -v rsyslogd >/dev/null 2>&1; then
    mkdir -p /etc/rsyslog.d
    RSYSLOG_DROPIN="/etc/rsyslog.d/99-neohiro-rate-limit.conf"
    cat > "${RSYSLOG_DROPIN}.tmp" <<'RSYSLOGRATE'
# neohiro/linux rate limiting — prevent log floods
$SystemLogRateLimitInterval 5
$SystemLogRateLimitBurst 200
$ImuxsockRateLimitInterval 5
$ImuxsockRateLimitBurst 500
# Limit per-process log rate
$ModLoad imuxsock
$IMUXSockRateLimitInterval 5
$IMUXSockRateLimitBurst 500
RSYSLOGRATE
    mv "${RSYSLOG_DROPIN}.tmp" "$RSYSLOG_DROPIN"
    systemctl reload rsyslog 2>/dev/null || systemctl restart rsyslog 2>/dev/null
fi

if [ -f /etc/syslog-ng/syslog-ng.conf ] || command -v syslog-ng >/dev/null 2>&1; then
    mkdir -p /etc/syslog-ng/conf.d
    SYSLOGNG_DROPIN="/etc/syslog-ng/conf.d/99-neohiro-rate-limit.conf"
    cat > "${SYSLOGNG_DROPIN}.tmp" <<'SYSLOGNGRATE'
# neohiro/linux rate limiting — prevent log floods
options {
    log-fifo-size(1000);
    flush-lines(100);
    flush-timeout(10000);
    time-reopen(60);
    log-msg-size(65536);
    stats-freq(0);
    mark-freq(0);
};
source s_src {
    system();
    internal();
};
destination d_rate_limit {
    file("/var/log/messages" flush-lines(100) flush-timeout(10000));
};
log { source(s_src); destination(d_rate_limit); };
SYSLOGNGRATE
    mv "${SYSLOGNG_DROPIN}.tmp" "$SYSLOGNG_DROPIN"
    systemctl reload syslog-ng 2>/dev/null || systemctl restart syslog-ng 2>/dev/null
fi

# 18. Auditd log limits (if auditd installed)
if command -v auditd >/dev/null 2>&1 || [ -f /etc/audit/auditd.conf ]; then
    msg "Configuring auditd log limits (1MB)..."
    mkdir -p /etc/audit
    AUDITD_CONF="/etc/audit/auditd.conf"
    # Atomic rewrite of auditd.conf
    {
        grep -vE '^(#?)(max_log_file|num_logs|max_log_file_action)=' "$AUDITD_CONF" 2>/dev/null || true
        cat <<'EOF'
max_log_file = 1
num_logs = 2
max_log_file_action = ROTATE
EOF
    } > "${AUDITD_CONF}.tmp" && mv "${AUDITD_CONF}.tmp" "$AUDITD_CONF"
    systemctl reload auditd 2>/dev/null || systemctl restart auditd 2>/dev/null
fi

# ── Storage Breakdown Analysis ────────────────────────────────────────
# Categorize disk usage by type for the summary.
# Runs a single 'du' pass per category to avoid double-counting and minimize I/O.
analyze_storage_breakdown() {
    local target_mount="${1:-/}"
    # Validate target_mount is an absolute path under root
    case "$target_mount" in
        /*) ;;
        *) target_mount="/" ;;
    esac
    
    local breakdown_file
    breakdown_file=$(mktemp -t deepclean_breakdown_XXXXXX) || return 1
    
    # Categories: system (OS), user (homes), logs, cache, containers, other
    # Use single du per category with multiple paths to reduce syscalls
    {
        # System: OS directories (exclude /etc/local, /etc/skel to avoid user data)
        du -kx "$target_mount"/usr "$target_mount"/lib "$target_mount"/lib64 \
           "$target_mount"/bin "$target_mount"/sbin "$target_mount"/boot \
           "$target_mount"/opt "$target_mount"/etc 2>/dev/null \
           | awk '{sum+=$1} END {print "system " (sum+0)}'
        
        # User: home directories
        du -kx "$target_mount"/home "$target_mount"/root 2>/dev/null \
           | awk '{sum+=$1} END {print "user " (sum+0)}'
        
        # Logs: journal + syslog
        du -kx "$target_mount"/var/log 2>/dev/null \
           | awk '{sum+=$1} END {print "logs " (sum+0)}'
        
        # Cache: package caches + user caches
        # Note: user caches found via find to avoid traversing all home dirs with du
        {
            du -kx "$target_mount"/var/cache "$target_mount"/var/lib/apt/lists \
               "$target_mount"/var/lib/dnf "$target_mount"/var/lib/pacman/pkg \
               "$target_mount"/var/lib/snapd/cache 2>/dev/null
            find "$target_mount"/home -maxdepth 3 -name '.cache' -type d -print0 2>/dev/null \
                | xargs -0r du -kx 2>/dev/null
        } | awk '{sum+=$1} END {print "cache " (sum+0)}'
        
        # Containers: docker, containerd, kubelet
        du -kx "$target_mount"/var/lib/docker "$target_mount"/var/lib/containerd \
           "$target_mount"/var/lib/kubelet 2>/dev/null \
           | awk '{sum+=$1} END {print "containers " (sum+0)}'
        
        # Other: computed as residual in caller
    } > "$breakdown_file" 2>/dev/null
    
    echo "$breakdown_file"
}

# ── Summary ─────────────────────────────────────────────────────────
df_output=$(df -kP / 2>/dev/null | tail -1) || df_output=""
if [ -n "$df_output" ]; then
    USED_AFTER_KB=$(echo "$df_output" | awk '{print $3}')
    case "$USED_AFTER_KB" in
        ''|*[!0-9]*) USED_AFTER_KB=0 ;;
    esac
else
    USED_AFTER_KB=0
fi
FREED_KB=$((USED_BEFORE_KB - USED_AFTER_KB))
[ "$FREED_KB" -lt 0 ] && FREED_KB=0
# FREED_MB and FREED_GB computed inline in summary output
# FREED_MB=$(awk "BEGIN {printf \"%.2f\", $FREED_KB/1024}")
# FREED_GB=$(awk "BEGIN {printf \"%.2f\", $FREED_KB/1048576}")

ROOT_INFO=$(df -hP / 2>/dev/null | tail -1) || ROOT_INFO=""
if [ -n "$ROOT_INFO" ]; then
    ROOT_TOTAL=$(echo "$ROOT_INFO" | awk '{print $2}')
    ROOT_FREE=$(echo "$ROOT_INFO" | awk '{print $4}')
    ROOT_PERCENT=$(echo "$ROOT_INFO" | awk '{print $5}')
else
    ROOT_TOTAL="unknown"
    ROOT_FREE="unknown"
    ROOT_PERCENT="unknown"
fi

# Capture breakdown AFTER cleaning
BREAKDOWN_AFTER_FILE=$(analyze_storage_breakdown "/") || BREAKDOWN_AFTER_FILE=""

declare -A AFTER_KB
if [ -n "$BREAKDOWN_AFTER_FILE" ] && [ -f "$BREAKDOWN_AFTER_FILE" ]; then
    while read -r cat kb; do
        case "$kb" in
            ''|*[!0-9]*) kb=0 ;;
        esac
        AFTER_KB["$cat"]="${kb:-0}"
    done < "$BREAKDOWN_AFTER_FILE"
fi
TOTAL_USED_AFTER_KB=${USED_AFTER_KB:-0}
SUM_CATS_AFTER=0
for cat in system user logs cache containers; do
    SUM_CATS_AFTER=$((SUM_CATS_AFTER + ${AFTER_KB[$cat]:-0}))
done
AFTER_KB["other"]=$((TOTAL_USED_AFTER_KB - SUM_CATS_AFTER))
[ "${AFTER_KB[other]}" -lt 0 ] && AFTER_KB["other"]=0

[ -n "$BREAKDOWN_AFTER_FILE" ] && rm -f "$BREAKDOWN_AFTER_FILE"

# Post-clean log audit
POST_LOG_KB=0
for log_path in /var/log/journal /var/log; do
    if [ -d "$log_path" ]; then
        size_kb=$(du -sk "$log_path" 2>/dev/null | awk '{print $1}')
        [ -n "$size_kb" ] && POST_LOG_KB=$((POST_LOG_KB + size_kb))
    fi
done

# Color gradient helpers for storage categories
_cat_color() {
    local cat="$1"
    case "$cat" in
        system)     _c '1;34m' "$2" ;;      # Blue
        user)       _c '1;32m' "$2" ;;      # Green
        logs)       _c '1;33m' "$2" ;;      # Yellow
        cache)      _c '1;35m' "$2" ;;      # Magenta
        containers) _c '1;36m' "$2" ;;      # Cyan
        other)      _c '1;37m' "$2" ;;      # White
        *)          _c '0m' "$2" ;;
    esac
}

_fmt_kb() {
    local kb="$1"
    if [ "$kb" -ge 1048576 ]; then
        # Use bash arithmetic for GB with 2 decimal places
        local gb_int=$((kb / 1048576))
        local gb_dec=$(( (kb % 1048576) * 100 / 1048576 ))
        printf '%d.%02d GB' "$gb_int" "$gb_dec"
    elif [ "$kb" -ge 1024 ]; then
        local mb_int=$((kb / 1024))
        local mb_dec=$(( (kb % 1024) * 100 / 1024 ))
        printf '%d.%02d MB' "$mb_int" "$mb_dec"
    else
        printf '%d KB' "$kb"
    fi
}

# Bar chart for visual breakdown
_draw_bar() {
    local used_kb="$1" total_kb="$2" width=30
    local pct=0
    [ "$total_kb" -gt 0 ] && pct=$((used_kb * 100 / total_kb))
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    # Build bar using printf repetition (faster than tr)
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf '[%s] %3d%%' "$bar" "$pct"
}

printf '\n%s\n' "$(_c '1;34m' '=================================================================')"
printf '%s\n' "$(_c '1;32m' '             DEEPCLEAN AND AUTO-PRUNE COMPLETE!')"
printf '%s\n\n' "$(_c '1;34m' '=================================================================')"

# Overall disk summary
printf '%s\n' "$(_c '1;36m' '┌─ Disk Overview ──────────────────────────────────────────────┐')"
printf '  Total Capacity : %s\n' "$(_c '1;34m' "${ROOT_TOTAL}")"
printf '  Before Clean   : %s\n' "$(_c '1;31m' "$(_fmt_kb "${USED_BEFORE_KB}") (${ROOT_PERCENT})")"
if [ "$FREED_KB" -gt 0 ]; then
    printf '  Freed          : %s\n' "$(_c '1;32m' "$(_fmt_kb "${FREED_KB}")")"
else
    printf '  Freed          : %s\n' "$(_c '1;33m' '0 KB')"
fi
printf '  After Clean    : %s\n' "$(_c '1;32m' "$(_fmt_kb "${USED_AFTER_KB}")")"
printf '  Free Space     : %s\n' "$(_c '1;32m' "${ROOT_FREE}")"
printf '%s\n\n' "$(_c '1;36m' '└──────────────────────────────────────────────────────────────┘')"

# Storage breakdown by category (before/after with bars)
printf '%s\n' "$(_c '1;36m' '┌─ Storage Breakdown by Category ───────────────────────────────┐')"
printf '  %-14s %12s → %12s  %s\n' "$(_c '1;37m' 'Category')" "$(_c '1;31m' 'Before')" "$(_c '1;32m' 'After')" "$(_c '1;37m' 'Visual')"
printf '  %s\n' "$(_c '1;90m' '────────────────────────────────────────────────────────────────')"

for cat in system user logs cache containers other; do
    before_kb=${BEFORE_KB[$cat]:-0}
    after_kb=${AFTER_KB[$cat]:-0}
    freed_cat=$((before_kb - after_kb))
    [ "$freed_cat" -lt 0 ] && freed_cat=0
    
    before_fmt=$(_fmt_kb "$before_kb")
    after_fmt=$(_fmt_kb "$after_kb")
    freed_fmt=$(_fmt_kb "$freed_cat")
    
    cat_label=$(_cat_color "$cat" "$(printf '%-12s' "$cat")")
    before_colored=$(_c '1;31m' "$(printf '%12s' "$before_fmt")")
    after_colored=$(_c '1;32m' "$(printf '%12s' "$after_fmt")")
    bar=$(_draw_bar "$after_kb" "$TOTAL_USED_AFTER_KB")
    
    printf '  %s %s → %s  %s\n' "$cat_label" "$before_colored" "$after_colored" "$bar"
    if [ "$freed_cat" -gt 0 ]; then
        printf '  %14s   %s\n' "" "$(_c '1;32m' "(-$freed_fmt)")"
    fi
done

printf '%s\n\n' "$(_c '1;36m' '└──────────────────────────────────────────────────────────────┘')"

# Log footprint
printf 'Log Footprint:\n'
printf '  Before: %s KB\n' "$(_c '1;34m' "${TOTAL_LOG_KB}")"
printf '  After : %s KB\n' "$(_c '1;32m' "${POST_LOG_KB}")"
if [ "$TOTAL_LOG_KB" -gt "$POST_LOG_KB" ]; then
    printf '  Freed : %s KB\n' "$(_c '1;32m' "$((TOTAL_LOG_KB - POST_LOG_KB))")"
fi

printf '\n%s\n' "$(_c '1;36m' 'Enforced 1MB Log Limits (reboot-proof):')"
printf '  systemd-journald   : SystemMaxUse=1M, SystemMaxFileSize=1M\n'
printf '  systemd-coredump   : MaxUse=1M, ExternalSizeMax=1M\n'
printf '  logrotate (global) : size 1M, rotate 1, daily\n'
printf '  logrotate (syslog) : /etc/logrotate.d/99-neohiro-syslog\n'
printf '  logrotate (pkg)    : /etc/logrotate.d/99-neohiro-pkg\n'
printf '  logrotate (ssh)    : /etc/logrotate.d/99-neohiro-ssh\n'
[ -f /etc/logrotate.d/99-neohiro-fail2ban ] && printf '  logrotate (fail2ban): /etc/logrotate.d/99-neohiro-fail2ban\n'
command -v docker >/dev/null 2>&1 && printf '  Docker             : json-file, max-size=1m, max-file=1\n'
command -v containerd >/dev/null 2>&1 && printf '  containerd         : max_log_size=1048576 (1MB), max_log_files=1\n'
command -v kubelet >/dev/null 2>&1 && printf '  kubelet            : --container-log-max-size=1Mi --container-log-max-files=1\n'
command -v auditd >/dev/null 2>&1 && printf '  auditd             : max_log_file=1MB, num_logs=2\n'
[ -f /etc/rsyslog.d/99-neohiro-rate-limit.conf ] && printf '  rsyslog rate limit : 200/5sec system, 500/5sec imuxsock\n'
[ -f /etc/syslog-ng/conf.d/99-neohiro-rate-limit.conf ] && printf '  syslog-ng rate lim : configured\n'
printf '\n%s\n' "$(_c '1;33m' 'All limits persist across reboots via drop-in configs.')"
printf '%s\n' "$(_c '1;33m' 'Run DeepClean.sh anytime to re-apply and audit.')"
