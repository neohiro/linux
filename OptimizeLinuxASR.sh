#!/usr/bin/env bash
# Holistic Linux Service Optimizer & Attack Surface Reducer
# Works on: Ubuntu / Debian / RHEL / AlmaLinux / Rocky / Fedora / SUSE / Arch
# Run as root:  sudo ./OptimizeLinuxASR.sh

# Color helpers from lib/color.sh (no-op if running via curl|bash).
# shellcheck disable=SC1091
if [ -r "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/color.sh" ]; then
  source "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/color.sh"
fi

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use sudo."
   exit 1
fi

# Read one line interactively. Falls back to /dev/tty when stdin is not a
# TTY (cron, sudo -i from a pipeline, etc.) so the script cannot hang.
# Usage: _read_tty <prompt> <var>
_read_tty() {
  local prompt="$1"
  if [ -t 0 ]; then
    read -r -p "$prompt"
  elif [ -e /dev/tty ] && [ -r /dev/tty ]; then
    printf '%s' "$prompt" >/dev/tty
    read -r REPLY </dev/tty
  else
    echo "stdin is not a TTY and /dev/tty is unavailable; defaulting." >&2
    REPLY=""
  fi
}

echo "============================================================================="
echo "         Linux Service Optimization & Attack Surface Reducer                 "
echo "============================================================================="
echo "You will be prompted to manage services by category."
echo "For each category, you can choose to:"
echo "  [i] Interact: Prompt for each service individually (Default)"
echo "  [a] Disable All: Bulk disable every applicable service in the category"
echo "  [s] Skip All: Bulk skip (keep) every service in the category"
echo "============================================================================="
echo ""

CATEGORY_ACTION="i"

ask_category() {
    local category_name="$1"
    echo ""
    echo "============================================================================="
    echo " CATEGORY: ${category_name}"
    echo "============================================================================="
    while true; do
        REPLY="" ; _read_tty "Action for this category? [i=Interactive / a=Disable All / s=Skip All] (Default i): "
        cat_choice="${REPLY,,}"
        case "$cat_choice" in
            a|all )
                CATEGORY_ACTION="a"
                echo " -> Action: DISABLING ALL applicable services in ${category_name}."
                break ;;
            s|skip|none )
                CATEGORY_ACTION="s"
                echo " -> Action: SKIPPING ALL services in ${category_name}."
                break ;;
            i|interactive|"")
                CATEGORY_ACTION="i"
                echo " -> Action: Interactive mode."
                break ;;
            *)
                echo "Invalid choice. Please enter i, a, or s." ;;
        esac
    done
    echo ""
}

ask_disable() {
    local service="$1"
    local description="$2"
    local default_choice="${3:-N}"

    if [[ "$CATEGORY_ACTION" == "s" ]]; then
        return
    fi

    if systemctl list-unit-files "${service}.service" >/dev/null 2>&1 || \
       systemctl list-unit-files "${service}" >/dev/null 2>&1 || \
       systemctl list-unit-files "${service}.socket" >/dev/null 2>&1; then
        local is_enabled is_active
        is_enabled=$(systemctl is-enabled "${service}" 2>/dev/null || echo "unknown")
        is_active=$(systemctl is-active "${service}" 2>/dev/null || echo "unknown")

        if [[ "$is_enabled" == "enabled" || "$is_active" == "active" ]]; then
            local choice
            if [[ "$CATEGORY_ACTION" == "a" ]]; then
                choice="y"
                echo "[BULK DISABLE] ${service}: ${description}"
            else
                REPLY="" ; _read_tty "Disable ${service} (${description})? [y/N]: "
                choice="$REPLY"
                [ -z "$choice" ] && choice="$default_choice"
            fi

            case "$choice" in
                [Yy]*)
                    echo " -> Stopping and disabling ${service}..."
                    systemctl stop "${service}" 2>/dev/null
                    systemctl disable "${service}" 2>/dev/null
                    systemctl mask "${service}" 2>/dev/null
                    echo " -> ${service} disabled." ;;
                *)
                    echo " -> Skipping ${service}." ;;
            esac
        else
            [[ "$CATEGORY_ACTION" == "i" ]] && \
                echo "[INFO] ${service} is already disabled or inactive. Skipping."
        fi
    else
        [[ "$CATEGORY_ACTION" == "i" ]] && \
            echo "[INFO] ${service} is not installed on this system. Skipping."
    fi

    [[ "$CATEGORY_ACTION" == "i" ]] && echo ""
}

# 1. Hardware & Peripherals
ask_category "Hardware & Peripherals"
ask_disable "bluetooth"      "Bluetooth daemon. Disable if you do not use Bluetooth devices."
ask_disable "cups"           "Common Unix Printing System. Disable if you do not print from this machine."
ask_disable "cups-browsed"   "Discovers shared network printers. Safe to disable if not printing."
ask_disable "ModemManager"   "Mobile broadband (2G/3G/4G) support. Disable if you don't use cellular modems."
ask_disable "pcscd"          "Smart Card Reader daemon. Disable if you don't use hardware security keys/smart cards."

# 2. Networking Services
ask_category "Networking Services"
ask_disable "avahi-daemon"        "mDNS/DNS-SD (Bonjour/Zeroconf). Often unneeded on servers."
ask_disable "nfs-server"           "Network File System server. Disable if you do not host NFS shares."
ask_disable "NetworkManager-wait-online" "Delays boot until network is connected. Can speed up boot."

# 3. Attack Surface Reduction & Legacy Protocols
ask_category "Attack Surface Reduction & Legacy Protocols"
ask_disable "rpcbind"     "Portmapper (RPC). High attack surface. Disable if no NFS or RPC mounts."
ask_disable "smbd"        "Samba SMB daemon. Disable if you are not sharing files with Windows networks."
ask_disable "nmbd"        "Samba NetBIOS daemon. Disable if you do not need legacy Windows discovery."
ask_disable "vsftpd"      "FTP server. Insecure protocol. Disable unless explicitly required."
ask_disable "proftpd"     "Alternative FTP server. Insecure protocol. Disable unless required."
ask_disable "pure-ftpd"   "Alternative FTP server. Insecure protocol. Disable unless required."
ask_disable "tftpd-hpa"   "TFTP. Unauthenticated. Disable unless needed for PXE booting."
ask_disable "snmpd"       "SNMP daemon. High attack surface if misconfigured."
ask_disable "rsyncd"      "Rsync daemon. Disable if you only use rsync over SSH."
ask_disable "telnet.socket" "Legacy Telnet. Extremely insecure. Disable unless required."
ask_disable "xinetd"      "Legacy inetd superserver. Rarely needed on modern systems."
ask_disable "inetd"       "Legacy inetd. Rarely needed on modern systems."
ask_disable "postfix"     "Mail Transfer Agent. Disable if this system does not send/receive mail directly."
ask_disable "exim4"       "Mail Transfer Agent. Disable if not needed."
ask_disable "apache2"     "Apache Web Server. Disable if this machine is not hosting websites."
ask_disable "nginx"       "Nginx Web Server. Disable if this machine is not hosting websites."

# 4. Storage & Virtualization
ask_category "Storage & Virtualization"
ask_disable "multipathd"   "Multi-path I/O daemon. Needed for enterprise storage; disable for standard local drives."
ask_disable "lvm2-monitor" "LVM monitoring. Disable ONLY if you are sure you do not use LVM."
ask_disable "iscsid"       "iSCSI daemon. Disable if you do not connect to iSCSI targets."
ask_disable "libvirtd"     "Virtualization daemon. Disable if you do not run KVM/QEMU VMs on this host."

# 5. Telemetry, Diagnostics & Updates
ask_category "Telemetry, Diagnostics & Updates"
ask_disable "apport"          "Crash reporting service (Ubuntu/Debian). Safe to disable for privacy."
ask_disable "whoopsie"        "Crash database submission daemon (Ubuntu/Debian). Safe to disable for privacy."
ask_disable "unattended-upgrades" "Auto security updates. Disable only if you prefer fully manual updates."
ask_disable "motd-news.timer" "Fetches Message-of-the-Day news on login. Safe to disable."

# 6. Snap & Package Management (Use Caution)
ask_category "Snap & Package Management"
ask_disable "snapd"  "Snap package manager. WARNING: disabling breaks snap applications."

# 7. Miscellaneous
ask_category "Miscellaneous"
ask_disable "speech-dispatcher" "Speech synthesis daemon. Usually unnecessary unless you use screen readers."
ask_disable "geoclue"          "Geolocation service. Often unneeded on servers."

echo "============================================================================="
echo "Optimization & Attack Surface Reduction complete!"
echo "You may want to reboot your system for all changes to take full effect."
echo "To re-enable a service:"
echo "  sudo systemctl unmask <service> && sudo systemctl enable --now <service>"
echo "============================================================================="
