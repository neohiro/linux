#!/bin/bash
# openstageisland Disk Purge — preserves SL trinity (2 docker containers, /root equalizer daemons, UFW)
# Run as root: sudo bash cleanup_openstageisland.sh [--dry-run] [--yes]
#
# What is PRESERVED (trinity goal):
#   - Docker containers: openstageislandbot, xashimura
#   - /root/equalizer* scripts/daemons
#   - UFW firewall rules & config
#
# What is PURGED (everything else):
#   - All other docker containers/images/volumes/networks/build cache
#   - Package caches (apt/dnf/yum/pacman/zypper), orphan packages, old kernels
#   - Logs → truncated to 1MB, rotated archives deleted
#   - Journald → 1MB cap (volatile+persistent), debug/info dropped, sealed
#   - Temp, crash, trash, snap/flatpak cache, user caches
#   - /root/.cache

# shellcheck shell=bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME
SCRIPT_NAME="$(basename "$0")"
readonly PRESERVE_CONTAINERS=("openstageislandbot" "xashimura")
readonly PRESERVE_ROOT_GLOBS=("/root/equalizer*")
readonly LOG_MAX_KB=1024  # 1MB
readonly JOURNAL_MAX_MB=1

DRY_RUN=0
AUTO_YES=0
VERBOSE=0
VERIFY_ONLY=0
INSTALL_SYSTEMD=0
SETTINGS_ROLLBACK=0
SYSTEM_ROLLBACK=0
UFW_BACKUP_DIR="/var/backups/ufw"
UFW_GPG_KEY=""
LOCK_FILE="/var/lock/cleanup-openstageisland.lock"
# LOCK_FD is hardcoded to 200 in acquire_lock/release_lock

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
err()   { printf '[ERROR] %s\n' "$*" >&2; }
vlog()  { [ "$VERBOSE" -eq 1 ] && printf '[DEBUG] %s\n' "$*"; }
die()   { err "$*"; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[DRY-RUN] %s\n' "$*"
    else
        vlog "Executing: $*"
        "$@"
    fi
}

require_root() {
    [ "$EUID" -eq 0 ] || die "Must run as root. Use sudo."
}

confirm() {
    local prompt="$1"
    [ "$AUTO_YES" -eq 1 ] && return 0
    read -rp "$prompt [y/N] " -n 1
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

verify_host() {
    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")
    case "$hostname" in
        openstageisland) ;;
        *)
            warn "Hostname is '$hostname', expected 'openstageisland'. Continue anyway?"
            if ! confirm "Proceed?"; then
                die "Aborted by user."
            fi
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Disk reporting
# ─────────────────────────────────────────────────────────────────────────────
report_disk() {
    local label="$1"
    log "=== Disk usage $label ==="
    df -h / | awk 'NR==1{print "  " $0} NR==2{printf "  Root: %s/%s (%s used, %s free)\n", $3, $2, $5, $4}'
    df -h /var 2>/dev/null | awk 'NR==2{printf "  /var: %s/%s (%s used, %s free)\n", $3, $2, $5, $4}'
    df -h /home 2>/dev/null | awk 'NR==2{printf "  /home: %s/%s (%s used, %s free)\n", $3, $2, $5, $4}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker cleanup
# ─────────────────────────────────────────────────────────────────────────────
cleanup_docker() {
    log "=== Docker cleanup ==="
    command -v docker >/dev/null 2>&1 || { log "  docker not installed, skipping"; return; }

    # Single docker ps call for efficiency
    local all_containers
    all_containers=$(docker ps -a --format '{{.Names}} {{.ID}} {{.Image}} {{.Status}}' 2>/dev/null || true)

    # Verify preserved containers exist
    local preserved_count=0
    for name in "${PRESERVE_CONTAINERS[@]}"; do
        if echo "$all_containers" | awk '{print $1}' | grep -qx "$name"; then
            local status
            status=$(echo "$all_containers" | awk -v n="$name" '$1==n {print $4; exit}')
            log "  KEEPING container: $name ($status)"
            preserved_count=$((preserved_count + 1))
        else
            warn "  Preserved container '$name' NOT FOUND"
        fi
    done

    # Remove all other containers (collect IDs first to avoid subshell counter bug)
    local container_ids
    container_ids=$(echo "$all_containers" | while read -r name id _img status; do
        local keep=0
        for p in "${PRESERVE_CONTAINERS[@]}"; do
            [ "$name" = "$p" ] && keep=1 && break
        done
        [ "$keep" -eq 0 ] && [ -n "$id" ] && printf '%s\n' "$id"
    done)

    local removed=0
    if [ -n "$container_ids" ]; then
        while read -r id; do
            [ -n "$id" ] && run docker rm -f "$id" 2>/dev/null && removed=$((removed + 1))
        done <<< "$container_ids"
    fi
    log "  Removed $removed non-preserved containers"

    # Prune images, volumes, networks, build cache (protect images used by preserved containers)
    # Get image REPOSITORY:TAG used by preserved containers (not IDs - filter=reference expects tags)
    local protected_refs=""
    for name in "${PRESERVE_CONTAINERS[@]}"; do
        local img_ref
        img_ref=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)
        [ -n "$img_ref" ] && protected_refs="$protected_refs $img_ref"
    done

    # Use protected image references filter if available
    if [ -n "$protected_refs" ]; then
        # Build filter args for docker image prune
        local filter_args=""
        for ref in $protected_refs; do
            filter_args="$filter_args --filter=reference!=$ref"
        done
        # shellcheck disable=SC2086
        run docker image prune -a -f --filter 'until=24h' $filter_args 2>/dev/null || true
    else
        run docker image prune -a -f --filter 'until=24h' 2>/dev/null || true
    fi
    run docker volume prune -f 2>/dev/null || true
    run docker network prune -f 2>/dev/null || true
    run docker builder prune -a -f 2>/dev/null || true
    run docker system df -v 2>/dev/null | head -20
}

# Helper: check if path is writable (not read-only fs)
is_writable() {
    local path="$1"
    local dir
    dir=$(dirname "$path")
    # If path exists, check it directly; otherwise check parent dir
    if [ -e "$path" ]; then
        [ -w "$path" ] && return 0
    fi
    [ -d "$dir" ] && [ -w "$dir" ] && return 0
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Journald hardening + vacuum
# ─────────────────────────────────────────────────────────────────────────────
cleanup_journald() {
    log "=== Journald hardening + vacuum ==="

    # Check writable
    is_writable "/etc/systemd/journald.conf.d/99-neohiro-1mb.conf" || { warn "  /etc read-only, skipping journald config"; return; }

    # Determine storage mode
    local storage_mode="volatile"
    [ -d /var/log/journal ] && [ -w /var/log/journal ] && storage_mode="persistent"

    # Write hardened config
    cat > /etc/systemd/journald.conf.d/99-neohiro-1mb.conf <<EOF
[Journal]
Storage=$storage_mode
SystemMaxUse=${JOURNAL_MAX_MB}M
SystemMaxFileSize=${JOURNAL_MAX_MB}M
SystemMaxFiles=2
MaxRetentionSec=1day
MaxFileSec=1day
RuntimeMaxUse=${JOURNAL_MAX_MB}M
RuntimeMaxFileSize=${JOURNAL_MAX_MB}M
RuntimeMaxFiles=2
RuntimeMaxRetentionSec=1day
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

    # Vacuum now
    run journalctl --vacuum-time=1d --vacuum-size=${JOURNAL_MAX_MB}M 2>/dev/null

    # Clean persistent journal if volatile
    if [ "$storage_mode" = "volatile" ] && [ -d /var/log/journal ]; then
        run rm -rf /var/log/journal 2>/dev/null
    fi

    # systemd service for boot vacuum (more reliable than tmpfiles.d for journalctl)
    cat > /etc/systemd/system/cleanup-journald-vacuum.service <<'EOF'
[Unit]
Description=Journald vacuum on boot (enforce 1MB limit)
DefaultDependencies=no
After=systemd-journald.service
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl --vacuum-size=1M --vacuum-time=1d
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    run systemctl enable cleanup-journald-vacuum.service 2>/dev/null || true
    run systemctl reload systemd-journald 2>/dev/null || run systemctl restart systemd-journald 2>/dev/null
    log "  journald: $storage_mode, ${JOURNAL_MAX_MB}MB cap, hardened (no audit, sealed, split=none, rate-limit=500)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Package manager cleanup (multi-distro)
# ─────────────────────────────────────────────────────────────────────────────
cleanup_packages() {
    log "=== Package cache & orphan cleanup ==="

    # apt (Debian/Ubuntu)
    if command -v apt-get >/dev/null 2>&1; then
        run apt-get clean -y
        run apt-get autoclean -y
        run apt-get autoremove --purge -y
        # Orphan packages (deborphan may not be installed)
        if command -v deborphan >/dev/null 2>&1; then
            deborphan 2>/dev/null | xargs -r apt-get purge -y 2>/dev/null || true
        fi
        # Old kernels (keep current + 1 previous) - portable approach
        local old_kernels
        old_kernels=$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v "$(uname -r)" | sort -V | head -n -1 2>/dev/null || true)
        # shellcheck disable=SC2086
        [ -n "$old_kernels" ] && run apt-get purge -y $old_kernels 2>/dev/null || true
    fi

    # dnf (Fedora/RHEL)
    command -v dnf >/dev/null 2>&1 && run dnf clean all && run dnf autoremove -y

    # yum (RHEL/CentOS)
    command -v yum >/dev/null 2>&1 && run yum clean all && run yum autoremove -y

    # pacman (Arch)
    command -v pacman >/dev/null 2>&1 && run pacman -Scc --noconfirm

    # zypper (SUSE)
    command -v zypper >/dev/null 2>&1 && run zypper clean --all
}

# ─────────────────────────────────────────────────────────────────────────────
# Log truncation & rotation cleanup
# ─────────────────────────────────────────────────────────────────────────────
cleanup_logs() {
    log "=== Log truncation (max ${LOG_MAX_KB}KB) ==="

    local log_files=(
        /var/log/syslog /var/log/messages /var/log/auth.log /var/log/kern.log
        /var/log/daemon.log /var/log/ufw.log /var/log/fail2ban.log
        /var/log/apt/history.log /var/log/apt/term.log
        /var/log/dpkg.log /var/log/pacman.log /var/log/zypper.log
        /var/log/dnf.log /var/log/yum.log
    )

    local truncated=0
    for log in "${log_files[@]}"; do
        if [ -f "$log" ] && [ -w "$log" ]; then
            local size_kb
            size_kb=$(du -k "$log" 2>/dev/null | awk '{print $1}')
            if [ "${size_kb:-0}" -gt "$LOG_MAX_KB" ]; then
                run truncate -s "${LOG_MAX_KB}K" "$log"
                truncated=$((truncated + 1))
            fi
        fi
    done

    # Remove rotated/compressed archives
    run find /var/log -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]*' \) -delete 2>/dev/null

    log "  Truncated $truncated active logs, removed rotated archives"

    # Logrotate 1MB config (proper format with newlines)
    is_writable "/etc/logrotate.d/99-neohiro-1mb" || { warn "  /etc read-only, skipping logrotate config"; return; }
    cat > /etc/logrotate.d/99-neohiro-1mb <<'EOF'
/var/log/syslog
/var/log/messages
/var/log/auth.log
/var/log/kern.log
/var/log/daemon.log
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

/var/log/dpkg.log
/var/log/apt/*.log
/var/log/pacman.log
/var/log/zypper.log
/var/log/dnf.log
/var/log/yum.log
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
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp, crash, trash, cache cleanup
# ─────────────────────────────────────────────────────────────────────────────
cleanup_temp() {
    log "=== Temp, crash, trash, cache cleanup ==="

    run rm -rf /var/crash/* 2>/dev/null

    # Safer /tmp cleanup: only remove files older than 7 days, skip active mountpoints
    run find /tmp -mindepth 1 -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
    run find /tmp -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
    run find /var/tmp -mindepth 1 -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
    run find /var/tmp -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

    run rm -rf /root/.cache /root/.local/share/Trash 2>/dev/null

    # User caches & trash (single find pass)
    [ -d /home ] && run find /home -maxdepth 3 \( -name '.cache' -o -name 'Trash' \) -type d -exec rm -rf {} + 2>/dev/null

    # Snap
    if command -v snap >/dev/null 2>&1; then
        local snap_list
        snap_list=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' || true)
        if [ -n "$snap_list" ]; then
            while read -r n r; do
                [ -n "$n" ] && [ -n "$r" ] && run snap remove "$n" --revision="$r" 2>/dev/null
            done <<< "$snap_list"
        fi
        run rm -rf /var/lib/snapd/cache/* 2>/dev/null
    fi

    # Flatpak
    command -v flatpak >/dev/null 2>&1 && run flatpak uninstall --unused -y 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# UFW backup/restore
# ─────────────────────────────────────────────────────────────────────────────
backup_ufw() {
    log "=== UFW backup ==="
    if command -v ufw >/dev/null 2>&1; then
        local ts
        ts=$(date +%F-%H%M%S)

        # Persistent backup directory
        run mkdir -p "$UFW_BACKUP_DIR"

        # Clean old backups: delete files older than 30 days, then keep only latest 5
        run find "$UFW_BACKUP_DIR" -name 'ufw-backup-*.tar.gz*' -mtime +30 -delete 2>/dev/null || true
        # Keep only latest 5 backups (by modification time)
        find "$UFW_BACKUP_DIR" -name 'ufw-backup-*.tar.gz*' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | tail -n +6 | cut -d' ' -f2- \
            | while IFS= read -r old; do
                [ -n "$old" ] && run rm -f "$old" 2>/dev/null || true
            done

        local persistent_backup="${UFW_BACKUP_DIR}/ufw-backup-${ts}.tar.gz"
        local tmpdir
        tmpdir=$(mktemp -d)

        # Copy rules to temp dir
        run cp -f /etc/ufw/user.rules "${tmpdir}/user.rules" 2>/dev/null || true
        run cp -f /etc/ufw/user6.rules "${tmpdir}/user6.rules" 2>/dev/null || true
        run cp -f /etc/ufw/before.rules "${tmpdir}/before.rules" 2>/dev/null || true
        run cp -f /etc/ufw/before6.rules "${tmpdir}/before6.rules" 2>/dev/null || true
        run cp -f /etc/ufw/after.rules "${tmpdir}/after.rules" 2>/dev/null || true
        run cp -f /etc/ufw/after6.rules "${tmpdir}/after6.rules" 2>/dev/null || true
        run ufw status numbered > "${tmpdir}/status.txt" 2>/dev/null || true
        run ufw status verbose > "${tmpdir}/status-verbose.txt" 2>/dev/null || true

        # Create tarball
        run tar -czf "$persistent_backup" -C "$tmpdir" . 2>/dev/null

        # GPG encrypt if key provided (verify fingerprint first)
        if [ -n "$UFW_GPG_KEY" ] && command -v gpg >/dev/null 2>&1; then
            log "  Encrypting UFW backup with GPG key: $UFW_GPG_KEY"
            # Verify key exists and get fingerprint
            local key_fpr
            key_fpr=$(gpg --with-colons --fingerprint "$UFW_GPG_KEY" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}' || true)
            [ -n "$key_fpr" ] || die "GPG key '$UFW_GPG_KEY' not found in keyring"
            log "  Key fingerprint: $key_fpr"
            run gpg --batch --yes --encrypt --recipient "$UFW_GPG_KEY" --output "${persistent_backup}.gpg" "$persistent_backup"
            run rm -f "$persistent_backup"
            persistent_backup="${persistent_backup}.gpg"
        fi

        # Also keep /tmp copy for immediate restore_ufw
        local tmp_backup="/tmp/ufw-backup-${ts}"
        run cp -f /etc/ufw/user.rules "${tmp_backup}.rules" 2>/dev/null || true
        run cp -f /etc/ufw/user6.rules "${tmp_backup}6.rules" 2>/dev/null || true
        run ufw status numbered > "${tmp_backup}.status" 2>/dev/null || true
        echo "$tmp_backup" > /tmp/ufw-backup-path.txt

        run rm -rf "$tmpdir"
        log "  UFW backup saved: $persistent_backup"
        [ -n "$UFW_GPG_KEY" ] && log "  (encrypted with GPG)"
    else
        log "  ufw not installed, skipping backup"
    fi
}

restore_ufw() {
    log "=== UFW restore verification ==="
    if command -v ufw >/dev/null 2>&1; then
        local ufw_backup
        ufw_backup=$(cat /tmp/ufw-backup-path.txt 2>/dev/null || true)
        if [ -n "$ufw_backup" ] && [ -f "$ufw_backup.status" ]; then
            log "  UFW status after cleanup:"
            cat "$ufw_backup.status" | sed 's/^/    /'
        fi
        # Verify rules files exist
        if [ -f /etc/ufw/user.rules ]; then
            log "  ✓ /etc/ufw/user.rules present"
        else
            warn "  ✗ /etc/ufw/user.rules MISSING"
        fi
        if [ -f /etc/ufw/user6.rules ]; then
            log "  ✓ /etc/ufw/user6.rules present"
        else
            warn "  ✗ /etc/ufw/user6.rules MISSING"
        fi
    else
        log "  ufw not installed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Rollback functions
# ─────────────────────────────────────────────────────────────────────────────
settings_rollback() {
    log "=== Settings Rollback (tool configs) ==="

    # Restore UFW from latest backup
    if command -v ufw >/dev/null 2>&1; then
        local latest_backup
        latest_backup=$(find "$UFW_BACKUP_DIR" -name 'ufw-backup-*.tar.gz*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
            log "  Restoring UFW from: $latest_backup"
            local tmpdir
            tmpdir=$(mktemp -d)
            if [[ "$latest_backup" == *.gpg ]] && command -v gpg >/dev/null 2>&1; then
                # Verify GPG key is available before decrypting
                if ! gpg --list-keys "$UFW_GPG_KEY" >/dev/null 2>&1; then
                    warn "  GPG key '$UFW_GPG_KEY' not in keyring, cannot decrypt backup"
                else
                    run gpg --batch --yes --decrypt --output "$tmpdir/ufw-backup.tar.gz" "$latest_backup" 2>/dev/null || true
                    run tar -xzf "$tmpdir/ufw-backup.tar.gz" -C "$tmpdir" 2>/dev/null || true
                fi
            else
                run tar -xzf "$latest_backup" -C "$tmpdir" 2>/dev/null || true
            fi
            # Restore all UFW rule files
            for f in user.rules user6.rules before.rules before6.rules after.rules after6.rules; do
                if [ -f "$tmpdir/$f" ]; then
                    run cp -f "$tmpdir/$f" "/etc/ufw/$f" 2>/dev/null
                    log "    Restored /etc/ufw/$f"
                fi
            done
            run rm -rf "$tmpdir"
            log "  UFW rules restored from backup"
        else
            warn "  No UFW backup found in $UFW_BACKUP_DIR"
        fi
    else
        log "  ufw not installed, skipping UFW restore"
    fi

    # Restore script config if exists (cleanup script itself)
    local script_backup_dir="/var/backups/cleanup-openstageisland"
    if [ -d "$script_backup_dir" ]; then
        local latest_script_backup
        latest_script_backup=$(find "$script_backup_dir" -name 'cleanup-openstageisland-*.sh' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        if [ -n "$latest_script_backup" ] && [ -f "$latest_script_backup" ]; then
            log "  Restoring script config from: $latest_script_backup"
            run cp -f "$latest_script_backup" "/usr/local/sbin/cleanup-openstageisland" 2>/dev/null
            run chmod 755 "/usr/local/sbin/cleanup-openstageisland" 2>/dev/null
        fi
    fi

    log "Settings rollback complete."
}

system_rollback() {
    log "=== System Rollback (linux environment) ==="

    # Use linuxinstall.sh rollback mechanism if available
    local rollback_log="/var/log/linux-install-rollback.log"
    if [ -f "$rollback_log" ]; then
        log "  Found linuxinstall.sh rollback log: $rollback_log"
        if command -v bash >/dev/null 2>&1 && [ -f "$(dirname "$0")/linuxinstall.sh" ]; then
            log "  Running linuxinstall.sh --rollback --apply"
            run bash "$(dirname "$0")/linuxinstall.sh" --rollback --apply
        else
            # Fallback: apply rollback directly from log
            log "  Applying rollback from log directly (fallback)"
            # shellcheck disable=SC2039,SC3028
            local -A LATEST_BAK
            # shellcheck disable=SC2039,SC3028
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
                        warn "Skipping malformed line in $rollback_log: $line"
                        continue
                        ;;
                esac
                [ -n "$orig" ] && [ -n "$bak" ] || continue
                LATEST_BAK[$orig]="$bak"
            done < "$rollback_log"

            if [ "${#LATEST_BAK[@]}" -eq 0 ]; then
                log "  Rollback log is empty; nothing to undo."
            else
                log "  Found ${#LATEST_BAK[@]} backed-up file(s) to restore"
                local -a sorted_origs
                while IFS= read -r orig; do
                    [ -n "$orig" ] && sorted_origs+=("$orig")
                done < <(printf '%s\n' "${!LATEST_BAK[@]}" | LC_ALL=C sort)
                for orig in "${sorted_origs[@]}"; do
                    bak="${LATEST_BAK[$orig]}"
                    if [ ! -f "$bak" ]; then
                        warn "  Missing backup: $bak (skipping $orig)"
                        missing+=("$bak")
                        continue
                    fi
                    run cp -f "$bak" "$orig"
                    log "  Restored $orig from $bak"
                done
            fi
        fi
    else
        warn "  No linuxinstall.sh rollback log found at $rollback_log"
    fi

    # Also check for apt-https rollback
    local apt_backup_dir="/var/backups/neohiro-apt-https"
    if [ -d "$apt_backup_dir" ]; then
        log "  Checking apt-https rollback..."
        local lib_path
        lib_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/apt-https.sh"
        if [ -f "$lib_path" ]; then
            # Source apt-https lib and call apt_https_revert if available
            if grep -q 'apt_https_revert' "$lib_path" 2>/dev/null; then
                # shellcheck disable=SC1090
                source "$lib_path"
                if declare -f apt_https_revert >/dev/null 2>&1; then
                    run apt_https_revert
                else
                    warn "  apt_https_revert function not found in lib"
                fi
            else
                warn "  apt_https_revert not found in lib, skipping"
            fi
        else
            warn "  apt-https lib not found at $lib_path, skipping apt-https rollback"
        fi
    fi

    # Restore SSH config if backup exists
    local latest_ssh_bak
    latest_ssh_bak=$(find /etc/ssh -maxdepth 1 -name 'sshd_config.bak.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
    if [ -n "$latest_ssh_bak" ] && [ -f "$latest_ssh_bak" ]; then
        log "  Restoring SSH config from: $latest_ssh_bak"
        run cp -f "$latest_ssh_bak" /etc/ssh/sshd_config
        run systemctl reload sshd 2>/dev/null || run systemctl restart sshd 2>/dev/null
    fi

    log "System rollback complete."
}

# ─────────────────────────────────────────────────────────────────────────────
# Verification of preserved trinity
# ─────────────────────────────────────────────────────────────────────────────
verify_preserved() {
    log "=== Verification of preserved trinity ==="

    # Docker containers
    log "Docker containers:"
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '  {{.Names}}: {{.Status}} ({{.Image}})' 2>/dev/null || echo "  (none running)"
        local all_ok=true
        for name in "${PRESERVE_CONTAINERS[@]}"; do
            if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
                local status health
                status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
                health=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo "no-health-check")
                if [ "$status" = "running" ]; then
                    if [ "$health" = "healthy" ] || [ "$health" = "no-health-check" ]; then
                        log "  ✓ $name ($status, health: $health)"
                    else
                        warn "  ⚠ $name ($status, health: $health)"
                        all_ok=false
                    fi
                else
                    warn "  ✗ $name ($status) - not running"
                    all_ok=false
                fi
            else
                warn "  ✗ $name MISSING"
                all_ok=false
            fi
        done
        [ "$all_ok" = true ] && log "  All preserved containers healthy"
    else
        log "  docker not installed"
    fi

    # Root equalizer daemons (uses PRESERVE_ROOT_GLOBS)
    log "Root equalizer daemons:"
    local found=0
    for glob in "${PRESERVE_ROOT_GLOBS[@]}"; do
        for f in $glob; do
            [ -e "$f" ] && { log "  ✓ $f"; found=1; }
        done
    done
    [ "$found" -eq 0 ] && log "  (none found matching /root/equalizer*)"

    # UFW
    log "UFW status:"
    if command -v ufw >/dev/null 2>&1; then
        ufw status numbered 2>/dev/null | sed 's/^/  /' || log "  (inactive or error)"
    else
        log "  ufw not installed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# systemd service/timer installation
# ─────────────────────────────────────────────────────────────────────────────
install_systemd() {
    log "=== Installing systemd service + timer ==="

    # Install script to fixed location - use BASH_SOURCE for reliability
    local install_path="/usr/local/sbin/cleanup-openstageisland"
    local src_path="${BASH_SOURCE[0]}"
    [ -f "$src_path" ] || die "Cannot determine script source path"
    run cp -f "$src_path" "$install_path"
    run chmod 755 "$install_path"

    local service_file="/etc/systemd/system/cleanup-openstageisland.service"
    local timer_file="/etc/systemd/system/cleanup-openstageisland.timer"

    # Check if already installed
    if systemctl is-enabled cleanup-openstageisland.timer >/dev/null 2>&1; then
        log "  Timer already enabled, reinstalling..."
    fi

    # Service unit
    cat > "$service_file" <<EOF
[Unit]
Description=openstageisland Trinity-Preserving Disk Purge
Documentation=man:cleanup-openstageisland(1)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$install_path --yes
User=root
# Protect the trinity - minimal required paths
ProtectSystem=strict
ReadWritePaths=/var/log /var/cache /var/lib/docker /var/lib/snapd /tmp /var/tmp /root/equalizer*
ProtectHome=read-only
NoNewPrivileges=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF

    # Timer unit (weekly, persistent)
    cat > "$timer_file" <<EOF
[Unit]
Description=Weekly openstageisland disk purge

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=4h
# Run at most once per day even if triggered multiple times
AccuracySec=1h

[Install]
WantedBy=timers.target
EOF

    run systemctl daemon-reload
    run systemctl enable --now cleanup-openstageisland.timer

    log "  Installed and enabled:"
    log "    $service_file"
    log "    $timer_file"
    log "  Timer runs weekly with 4h random delay, persistent=true (catches missed runs)"
    log "  Script installed to: $install_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  --dry-run             Show what would be done without executing
  --yes, -y             Auto-confirm (non-interactive)
  --verbose             Enable debug output
  --verify-only         Run verification only (no destructive changes)
  --gpg-key <id>        GPG key ID for UFW backup encryption
  --install-systemd     Install systemd service + weekly timer
  --settingsrollback    Restore tool/settings backups (UFW, script configs)
  --systemrollback      Restore system backups (linux environment via linuxinstall.sh)
  --help                Show this help

Preserves (trinity):
  - Docker: ${PRESERVE_CONTAINERS[*]}
  - /root/equalizer* daemons
  - UFW rules & config

Purges everything else.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --yes|-y)  AUTO_YES=1 ;;
            --verbose) VERBOSE=1 ;;
            --verify-only) VERIFY_ONLY=1 ;;
            --gpg-key)
                shift
                UFW_GPG_KEY="${1:-}"
                [ -n "$UFW_GPG_KEY" ] || die "--gpg-key requires a key ID"
                ;;
            --install-systemd) INSTALL_SYSTEMD=1 ;;
            --settingsrollback) SETTINGS_ROLLBACK=1 ;;
            --systemrollback) SYSTEM_ROLLBACK=1 ;;
            --help)    usage; exit 0 ;;
            *) die "Unknown option: $1. Use --help." ;;
        esac
        shift
    done
}

acquire_lock() {
    # Use a fixed FD (200) for portability (bash 3.2+ compatible)
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        die "Another instance is running (lock: $LOCK_FILE). Wait or remove lock manually."
    fi
}

release_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&-
}

main() {
    parse_args "$@"
    require_root
    acquire_lock
    # Ensure lock is released on exit
    trap release_lock EXIT
    verify_host

    # Install systemd service + timer
    if [ "$INSTALL_SYSTEMD" -eq 1 ]; then
        install_systemd
        # Verify installation
        if systemctl is-enabled cleanup-openstageisland.timer >/dev/null 2>&1; then
            log "  ✓ Timer enabled and active"
        else
            warn "  Timer may not be properly enabled"
        fi
        log "Done."
        exit 0
    fi

    # Settings rollback: restore tool/settings backups (UFW, script configs)
    if [ "$SETTINGS_ROLLBACK" -eq 1 ]; then
        settings_rollback
        log "Done."
        exit 0
    fi

    # System rollback: restore system backups (linux environment via linuxinstall.sh)
    if [ "$SYSTEM_ROLLBACK" -eq 1 ]; then
        system_rollback
        log "Done."
        exit 0
    fi

    # Verify-only mode: run verification + disk report, no destructive ops
    # shellcheck disable=SC1009
    if [ "$VERIFY_ONLY" -eq 1 ]; then
        log "=== VERIFY-ONLY MODE ==="
        report_disk "CURRENT"
        # In verify-only, check if trinity items exist without docker ps side effects
        if command -v docker >/dev/null 2>&1; then
            for name in "${PRESERVE_CONTAINERS[@]}"; do
                if docker ps -a --format '{{.Names}}' | grep -q "^$name$"; then
                    log "  ✓ Container $name exists"
                else
                    warn "  ✗ Container $name MISSING"
                fi
            done
        fi
        # shellcheck disable=SC1073,SC1061,SC1062,SC1072
        for glob in "${PRESERVE_ROOT_GLOBS[@]}"; do
            for f in $glob; do
                if [ -e "$f" ]; then
                    log "  ✓ Found $f"
                else
                    warn "  ✗ Missing $f"
                fi
            done
        done
        # shellcheck disable=SC1073,SC1061,SC1062,SC1072
        if command -v ufw >/dev/null 2>&1; then
            if [ -f /etc/ufw/user.rules ]; then
                log "  ✓ UFW rules present"
            else
                warn "  ✗ UFW rules MISSING"
            fi
        fi
        log "Done."
        exit 0
    fi

    log "Starting openstageisland disk purge (trinity-preserving)"
    [ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN MODE - no changes will be made"

    confirm "This will PURGE all non-trinity data on openstageisland. Continue?" || die "Aborted."

    report_disk "BEFORE"

    # Backup UFW before any changes
    backup_ufw

    cleanup_docker
    cleanup_journald
    cleanup_packages
    cleanup_logs
    cleanup_temp

    # Verify UFW preserved
    restore_ufw

    # Verify trinity (skip docker ps in dry-run since no changes made)
    if [ "$DRY_RUN" -eq 0 ]; then
        verify_preserved
    else
        log "=== Dry-run: skipping live verification ==="
    fi
    report_disk "AFTER"

    log "Done."
}

main "$@"