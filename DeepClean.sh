#!/bin/bash
# Comprehensive Linux DeepClean & Auto-Prune Script
# Works on: Ubuntu / Debian (apt), RHEL / AlmaLinux / Rocky / Fedora (dnf/yum),
#           SUSE / openSUSE (zypper), Arch Linux (pacman)
# Run as root:  sudo ./DeepClean.sh

set -euo pipefail

USED_BEFORE_KB=$(df -kP / | tail -1 | awk '{print $3}')

msg()  { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*"; }

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

msg "Detected package manager: ${PM:-none}"
msg "Starting DeepClean..."

# 1. Systemd Journal Logs
msg "Cleaning systemd journal logs..."
journalctl --vacuum-time=1d  2>/dev/null || true
journalctl --vacuum-size=50M  2>/dev/null || true

# 2. Rotated and Compressed Logs
msg "Removing old rotated log files in /var/log..."
find /var/log -type f -regex ".*\.[0-9]$" -delete 2>/dev/null || true
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.xz" -delete 2>/dev/null || true

# 3. Active Legacy Logs
msg "Truncating active legacy log files..."
for log in /var/log/syslog /var/log/messages /var/log/auth.log \
           /var/log/kern.log /var/log/dpkg.log /var/log/daemon.log; do
    [ -f "$log" ] && truncate -s 0 "$log" 2>/dev/null || true
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
    LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' |
        while read -r snapname revision; do
            snap remove "$snapname" --revision="$revision" 2>/dev/null || true
        done
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

# 9. journald retention
msg "Configuring journald for automatic log retention..."
JOURNALD_CONF="/etc/systemd/journald.conf"
[ -f "$JOURNALD_CONF" ] || touch "$JOURNALD_CONF"
grep -qE "^#?SystemMaxUse=" "$JOURNALD_CONF" && \
    sed -i 's/^#*SystemMaxUse=.*/SystemMaxUse=200M/' "$JOURNALD_CONF" || \
    echo "SystemMaxUse=200M" >> "$JOURNALD_CONF"
grep -qE "^#?MaxRetentionSec=" "$JOURNALD_CONF" && \
    sed -i 's/^#*MaxRetentionSec=.*/MaxRetentionSec=7d/' "$JOURNALD_CONF" || \
    echo "MaxRetentionSec=7d" >> "$JOURNALD_CONF"
systemctl restart systemd-journald 2>/dev/null || true

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

# 11. systemd-coredump limits
msg "Configuring systemd-coredump limits..."
COREDUMP_CONF="/etc/systemd/coredump.conf"
[ -f "$COREDUMP_CONF" ] || { echo "[Coredump]" > "$COREDUMP_CONF"; }
grep -qE "^#?MaxUse=" "$COREDUMP_CONF" && \
    sed -i 's/^#*MaxUse=.*/MaxUse=100M/' "$COREDUMP_CONF" || \
    echo "MaxUse=100M" >> "$COREDUMP_CONF"
systemctl restart systemd-coredump.socket 2>/dev/null || true

# 12. logrotate defaults
msg "Configuring global logrotate for shorter retention and compression..."
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#compress/compress/' /etc/logrotate.conf
    grep -q "^compress" /etc/logrotate.conf || echo "compress" >> /etc/logrotate.conf
    sed -i 's/^rotate 4/rotate 2/' /etc/logrotate.conf
fi

# ── Summary ─────────────────────────────────────────────────────────
USED_AFTER_KB=$(df -kP / | tail -1 | awk '{print $3}')
FREED_KB=$((USED_BEFORE_KB - USED_AFTER_KB))
[ "$FREED_KB" -lt 0 ] && FREED_KB=0
FREED_MB=$(awk "BEGIN {printf \"%.2f\", $FREED_KB/1024}")
FREED_GB=$(awk "BEGIN {printf \"%.2f\", $FREED_KB/1048576}")

ROOT_INFO=$(df -hP / | tail -1)
ROOT_FS=$(echo "$ROOT_INFO" | awk '{print $1}')
ROOT_TOTAL=$(echo "$ROOT_INFO" | awk '{print $2}')
ROOT_USED=$(echo "$ROOT_INFO" | awk '{print $3}')
ROOT_FREE=$(echo "$ROOT_INFO" | awk '{print $4}')
ROOT_PERCENT=$(echo "$ROOT_INFO" | awk '{print $5}')

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

echo -e "\n${BLUE}=================================================================${NC}"
echo -e "${GREEN}             DEEPCLEAN AND AUTO-PRUNE COMPLETE!                  ${NC}"
echo -e "${BLUE}=================================================================${NC}\n"

if [ "$FREED_KB" -gt 1024000 ]; then
    echo -e "Total Space Freed: ${GREEN}${FREED_GB} GB${NC} (${FREED_MB} MB)\n"
else
    echo -e "Total Space Freed: ${GREEN}${FREED_MB} MB${NC}\n"
fi

echo -e "Current Disk (${CYAN}${ROOT_FS}${NC}):"
echo -e "  Total : ${BLUE}${ROOT_TOTAL}${NC}"
echo -e "  Used  : ${BLUE}${ROOT_USED}${NC} (${ROOT_PERCENT})"
echo -e "  Free  : ${GREEN}${ROOT_FREE}${NC}\n"
echo -e "${BLUE}=================================================================${NC}\n"
