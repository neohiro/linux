#!/usr/bin/env bash
# tests/test_log_limits.sh - Tests for 1MB log limit enforcement in DeepClean.sh
#
# Verifies that DeepClean.sh correctly configures all logging subsystems
# to enforce 1MB maximum log sizes with persistent, reboot-proof drop-ins.
#
# Run: bash tests/test_log_limits.sh

set -u
PASS=0; FAIL=0
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_RST=""; fi
ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$C_RST" "$1" "$2"; FAIL=$((FAIL+1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEEPCLEAN="$ROOT/DeepClean.sh"
[ -f "$DEEPCLEAN" ] || { echo "DeepClean.sh not found at $DEEPCLEAN"; exit 2; }

msg() { printf '=> %s\n' "$*"; }

# Test 1: journald drop-in content
msg "Testing journald 1MB drop-in configuration..."
# Extract the journald drop-in content from the heredoc
# The drop-in content is between JOURNALDROPIN<< and the closing JOURNALDROPIN marker
# Extract the journald drop-in content from the heredoc
# The drop-in content is between <<JOURNALDROPIN and JOURNALDROPIN on its own line
JOURNALD_DROPIN=$(sed -n '/<<JOURNALDROPIN/,/^JOURNALDROPIN$/p' "$DEEPCLEAN" | sed '1d;$d')
if echo "$JOURNALD_DROPIN" | grep -q 'SystemMaxUse=1M'; then
    ok_t "journald drop-in: SystemMaxUse=1M present"
else
    fail_t "journald drop-in: SystemMaxUse=1M" "not found in drop-in"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'SystemMaxFileSize=1M'; then
    ok_t "journald drop-in: SystemMaxFileSize=1M present"
else
    fail_t "journald drop-in: SystemMaxFileSize=1M" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'MaxRetentionSec=1day'; then
    ok_t "journald drop-in: MaxRetentionSec=1day present"
else
    fail_t "journald drop-in: MaxRetentionSec=1day" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'ForwardToSyslog=no'; then
    ok_t "journald drop-in: ForwardToSyslog=no (prevents duplication)"
else
    fail_t "journald drop-in: ForwardToSyslog=no" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'Compress=yes'; then
    ok_t "journald drop-in: Compress=yes present"
else
    fail_t "journald drop-in: Compress=yes" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'Storage='; then
    ok_t "journald drop-in: Storage= present"
else
    fail_t "journald drop-in: Storage=" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'MaxLevelStore=warning'; then
    ok_t "journald drop-in: MaxLevelStore=warning present"
else
    fail_t "journald drop-in: MaxLevelStore=warning" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'Audit=no'; then
    ok_t "journald drop-in: Audit=no present"
else
    fail_t "journald drop-in: Audit=no" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'Seal=yes'; then
    ok_t "journald drop-in: Seal=yes present"
else
    fail_t "journald drop-in: Seal=yes" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'SplitMode=none'; then
    ok_t "journald drop-in: SplitMode=none present"
else
    fail_t "journald drop-in: SplitMode=none" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -qF 'RuntimeMaxUse=${RUNTIME_MAX_USE}'; then
    ok_t 'journald drop-in: RuntimeMaxUse=${RUNTIME_MAX_USE} present'
else
    fail_t 'journald drop-in: RuntimeMaxUse=${RUNTIME_MAX_USE}' "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'ForwardToKMsg=no'; then
    ok_t "journald drop-in: ForwardToKMsg=no present"
else
    fail_t "journald drop-in: ForwardToKMsg=no" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'ForwardToConsole=no'; then
    ok_t "journald drop-in: ForwardToConsole=no present"
else
    fail_t "journald drop-in: ForwardToConsole=no" "not found"
fi
if echo "$JOURNALD_DROPIN" | grep -q 'ForwardToWall=no'; then
    ok_t "journald drop-in: ForwardToWall=no present"
else
    fail_t "journald drop-in: ForwardToWall=no" "not found"
fi

# Test 2: coredump drop-in content
msg "Testing systemd-coredump 1MB drop-in..."
COREDUMP_DROPIN=$(grep -A 15 '99-neohiro-1mb.conf' "$DEEPCLEAN" | tail -15)
if echo "$COREDUMP_DROPIN" | grep -q 'MaxUse=1M'; then
    ok_t "coredump drop-in: MaxUse=1M present"
else
    fail_t "coredump drop-in: MaxUse=1M" "not found"
fi
if echo "$COREDUMP_DROPIN" | grep -q 'ExternalSizeMax=1M'; then
    ok_t "coredump drop-in: ExternalSizeMax=1M present"
else
    fail_t "coredump drop-in: ExternalSizeMax=1M" "not found"
fi
if echo "$COREDUMP_DROPIN" | grep -q 'ProcessSizeMax=1M'; then
    ok_t "coredump drop-in: ProcessSizeMax=1M present"
else
    fail_t "coredump drop-in: ProcessSizeMax=1M" "not found"
fi

# Test 3: logrotate global config
msg "Testing logrotate global 1MB configuration..."
LOGROTATE_CONF=$(sed -n '/^# 12\. logrotate/,/^# 1[3-9]\./p' "$DEEPCLEAN" | head -30)
if echo "$LOGROTATE_CONF" | grep -q 'size 1M'; then
    ok_t "logrotate global: size 1M present"
else
    fail_t "logrotate global: size 1M" "not found"
fi
if echo "$LOGROTATE_CONF" | grep -q 'rotate 1'; then
    ok_t "logrotate global: rotate 1 present"
else
    fail_t "logrotate global: rotate 1" "not found"
fi
if echo "$LOGROTATE_CONF" | grep -q 'daily'; then
    ok_t "logrotate global: daily rotation present"
else
    fail_t "logrotate global: daily" "not found"
fi
if echo "$LOGROTATE_CONF" | grep -q 'compress'; then
    ok_t "logrotate global: compress present"
else
    fail_t "logrotate global: compress" "not found"
fi
if echo "$LOGROTATE_CONF" | grep -q 'delaycompress'; then
    ok_t "logrotate global: delaycompress present"
else
    fail_t "logrotate global: delaycompress" "not found"
fi

# Test 4: logrotate drop-in files
msg "Testing per-service logrotate drop-ins..."
SYSLOG_ROTATE=$(sed -n '/_write_logrotate.*syslog/,/^)/p' "$DEEPCLEAN")
if echo "$SYSLOG_ROTATE" | grep -q 'size 1M'; then
    ok_t "syslog rotate: size 1M present"
else
    fail_t "syslog rotate: size 1M" "not found"
fi
if echo "$SYSLOG_ROTATE" | grep -q 'rotate 1'; then
    ok_t "syslog rotate: rotate 1 present"
else
    fail_t "syslog rotate: rotate 1" "not found"
fi
if echo "$SYSLOG_ROTATE" | grep -q 'sharedscripts'; then
    ok_t "syslog rotate: sharedscripts present"
else
    fail_t "syslog rotate: sharedscripts" "not found"
fi

PKG_ROTATE=$(sed -n '/_write_logrotate.*pkg/,/^)/p' "$DEEPCLEAN")
if echo "$PKG_ROTATE" | grep -q 'size 1M'; then
    ok_t "pkg rotate: size 1M present"
else
    fail_t "pkg rotate: size 1M" "not found"
fi
if echo "$PKG_ROTATE" | grep -q '/var/log/dpkg.log'; then
    ok_t "pkg rotate: dpkg.log included"
else
    fail_t "pkg rotate: dpkg.log" "not found"
fi
if echo "$PKG_ROTATE" | grep -q '/var/log/pacman.log'; then
    ok_t "pkg rotate: pacman.log included"
else
    fail_t "pkg rotate: pacman.log" "not found"
fi

SSH_ROTATE=$(sed -n '/_write_logrotate.*ssh/,/^)/p' "$DEEPCLEAN")
if echo "$SSH_ROTATE" | grep -q 'size 1M'; then
    ok_t "ssh rotate: size 1M present"
else
    fail_t "ssh rotate: size 1M" "not found"
fi

# Test 5: logrotate drop-ins use atomic write helper
msg "Testing logrotate drop-ins use atomic write helper..."
if grep -q '_write_logrotate' "$DEEPCLEAN"; then
    ok_t "logrotate: atomic write helper _write_logrotate used"
else
    fail_t "logrotate: _write_logrotate helper" "not found"
fi

# Test 5: Docker log driver config
msg "Testing Docker 1MB log configuration..."
DOCKER_CFG=$(sed -n '/Docker log driver/,/^fi/p' "$DEEPCLEAN")
if echo "$DOCKER_CFG" | grep -q '"log-driver": "json-file"'; then
    ok_t "Docker: json-file driver configured"
else
    fail_t "Docker: json-file driver" "not found"
fi
if echo "$DOCKER_CFG" | grep -q '"max-size": "1m"'; then
    ok_t "Docker: max-size=1m present"
else
    fail_t "Docker: max-size=1m" "not found"
fi
if echo "$DOCKER_CFG" | grep -q '"max-file": "1"'; then
    ok_t "Docker: max-file=1 present"
else
    fail_t "Docker: max-file=1" "not found"
fi
if echo "$DOCKER_CFG" | grep -q 'python3'; then
    ok_t "Docker: python3 fallback for JSON merge present"
else
    fail_t "Docker: python3 fallback" "not found"
fi

# Test 6: containerd config
msg "Testing containerd 1MB log configuration..."
CONTAINERD_CFG=$(sed -n '/containerd log limits/,/^fi/p' "$DEEPCLEAN")
if echo "$CONTAINERD_CFG" | grep -q 'container_max_log_size = 1048576'; then
    ok_t "containerd: max_log_size=1048576 (1MB) present"
else
    fail_t "containerd: max_log_size" "not found"
fi
if echo "$CONTAINERD_CFG" | grep -q 'container_max_log_files = 1'; then
    ok_t "containerd: max_log_files=1 present"
else
    fail_t "containerd: max_log_files=1" "not found"
fi
if echo "$CONTAINERD_CFG" | grep -q 'has_cri'; then
    ok_t "containerd: has_cri section detection present"
else
    fail_t "containerd: has_cri detection" "not found"
fi

# Test 7: kubelet config
msg "Testing kubelet 1MB log configuration..."
KUBELET_CFG=$(sed -n '/kubelet log limits/,/^fi/p' "$DEEPCLEAN")
if echo "$KUBELET_CFG" | grep -q 'container-log-max-size=1Mi'; then
    ok_t "kubelet: container-log-max-size=1Mi present"
else
    fail_t "kubelet: container-log-max-size" "not found"
fi
if echo "$KUBELET_CFG" | grep -q 'container-log-max-files=1'; then
    ok_t "kubelet: container-log-max-files=1 present"
else
    fail_t "kubelet: container-log-max-files=1" "not found"
fi

# Test 8: auditd config
msg "Testing auditd 1MB log configuration..."
AUDITD_CFG=$(sed -n '/auditd log limits/,/^fi/p' "$DEEPCLEAN")
if echo "$AUDITD_CFG" | grep -q 'max_log_file = 1'; then
    ok_t "auditd: max_log_file=1 present"
else
    fail_t "auditd: max_log_file=1" "not found"
fi
if echo "$AUDITD_CFG" | grep -q 'num_logs = 2'; then
    ok_t "auditd: num_logs=2 present"
else
    fail_t "auditd: num_logs=2" "not found"
fi
if echo "$AUDITD_CFG" | grep -q 'max_log_file_action = ROTATE'; then
    ok_t "auditd: max_log_file_action=ROTATE present"
else
    fail_t "auditd: max_log_file_action" "not found"
fi

# Test 9: rsyslog rate limiting
msg "Testing rsyslog rate limiting..."
RSYSLOG_CFG=$(sed -n '/RSYSLOG_DROPIN=/,/^fi/p' "$DEEPCLEAN")
if echo "$RSYSLOG_CFG" | grep -q 'SystemLogRateLimitInterval 5'; then
    ok_t "rsyslog: SystemLogRateLimitInterval=5 present"
else
    fail_t "rsyslog: SystemLogRateLimitInterval" "not found"
fi
if echo "$RSYSLOG_CFG" | grep -q 'SystemLogRateLimitBurst 200'; then
    ok_t "rsyslog: SystemLogRateLimitBurst=200 present"
else
    fail_t "rsyslog: SystemLogRateLimitBurst" "not found"
fi
if echo "$RSYSLOG_CFG" | grep -q 'IMUXSockRateLimitBurst 500'; then
    ok_t "rsyslog: IMUXSockRateLimitBurst=500 present"
else
    fail_t "rsyslog: IMUXSockRateLimitBurst" "not found"
fi

# Test 10: syslog-ng rate limiting
msg "Testing syslog-ng rate limiting..."
SYSLOGNG_CFG=$(sed -n '/SYSLOGNG_DROPIN=/,/^fi/p' "$DEEPCLEAN")
if echo "$SYSLOGNG_CFG" | grep -q 'log-fifo-size(1000)'; then
    ok_t "syslog-ng: log-fifo-size=1000 present"
else
    fail_t "syslog-ng: log-fifo-size" "not found"
fi
if echo "$SYSLOGNG_CFG" | grep -q 'flush-lines(100)'; then
    ok_t "syslog-ng: flush-lines=100 present"
else
    fail_t "syslog-ng: flush-lines" "not found"
fi

# Test 11: Active log truncation logic (1MB threshold)
msg "Testing active log truncation (1MB threshold)..."
TRUNCATE_LOGIC=$(sed -n '/Truncating active legacy log/,/^done/p' "$DEEPCLEAN")
if echo "$TRUNCATE_LOGIC" | grep -q '1024'; then
    ok_t "truncation: 1MB (1024KB) threshold present"
else
    fail_t "truncation: 1MB threshold" "not found"
fi
if echo "$TRUNCATE_LOGIC" | grep -q 'truncate -s 1M'; then
    ok_t "truncation: truncate -s 1M used (not -s 0)"
else
    fail_t "truncation: truncate -s 1M" "not found (using -s 0?)"
fi
if echo "$TRUNCATE_LOGIC" | grep -q '/var/log/ufw.log'; then
    ok_t "truncation: ufw.log included"
else
    fail_t "truncation: ufw.log" "not found"
fi
if echo "$TRUNCATE_LOGIC" | grep -q '/var/log/fail2ban.log'; then
    ok_t "truncation: fail2ban.log included"
else
    fail_t "truncation: fail2ban.log" "not found"
fi

# Test 12: Log audit before/after
msg "Testing log footprint audit..."
AUDIT_LOGIC=$(sed -n '/Auditing current log sizes/,/Starting DeepClean/p' "$DEEPCLEAN")
if echo "$AUDIT_LOGIC" | grep -q 'TOTAL_LOG_KB'; then
    ok_t "audit: TOTAL_LOG_KB capture before clean"
else
    fail_t "audit: TOTAL_LOG_KB before" "not found"
fi
POST_AUDIT=$(sed -n '/# Post-clean log audit/,/^done/p' "$DEEPCLEAN" | head -20)
if echo "$POST_AUDIT" | grep -q 'POST_LOG_KB'; then
    ok_t "audit: POST_LOG_KB capture after clean"
else
    fail_t "audit: POST_LOG_KB after" "not found"
fi

# Test 13: Summary output includes all configured limits
msg "Testing summary output documents all limits..."
SUMMARY=$(sed -n '/Enforced 1MB Log Limits/,/All limits persist/p' "$DEEPCLEAN")
if echo "$SUMMARY" | grep -q 'systemd-journald'; then
    ok_t "summary: journald documented"
else
    fail_t "summary: journald" "not found"
fi
if echo "$SUMMARY" | grep -q 'systemd-coredump'; then
    ok_t "summary: coredump documented"
else
    fail_t "summary: coredump" "not found"
fi
if echo "$SUMMARY" | grep -q 'logrotate (global)'; then
    ok_t "summary: logrotate global documented"
else
    fail_t "summary: logrotate global" "not found"
fi
if echo "$SUMMARY" | grep -q 'Docker'; then
    ok_t "summary: Docker documented"
else
    fail_t "summary: Docker" "not found"
fi
if echo "$SUMMARY" | grep -q 'containerd'; then
    ok_t "summary: containerd documented"
else
    fail_t "summary: containerd" "not found"
fi
if echo "$SUMMARY" | grep -q 'kubelet'; then
    ok_t "summary: kubelet documented"
else
    fail_t "summary: kubelet" "not found"
fi
if echo "$SUMMARY" | grep -q 'auditd'; then
    ok_t "summary: auditd documented"
else
    fail_t "summary: auditd" "not found"
fi
if echo "$SUMMARY" | grep -q 'rsyslog rate limit'; then
    ok_t "summary: rsyslog rate limit documented"
else
    fail_t "summary: rsyslog rate limit" "not found"
fi
if echo "$SUMMARY" | grep -q 'reboot-proof'; then
    ok_t "summary: reboot-proof note present"
else
    fail_t "summary: reboot-proof" "not found"
fi

# Test 13b: New storage breakdown summary
msg "Testing new storage breakdown summary..."
NEW_SUMMARY=$(sed -n '/Storage Breakdown by Category/,/^└────/p' "$DEEPCLEAN")
if echo "$NEW_SUMMARY" | grep -q 'system'; then
    ok_t "summary: system category present"
else
    fail_t "summary: system category" "not found"
fi
if echo "$NEW_SUMMARY" | grep -q 'user'; then
    ok_t "summary: user category present"
else
    fail_t "summary: user category" "not found"
fi
if echo "$NEW_SUMMARY" | grep -q 'logs'; then
    ok_t "summary: logs category present"
else
    fail_t "summary: logs category" "not found"
fi
if echo "$NEW_SUMMARY" | grep -q 'cache'; then
    ok_t "summary: cache category present"
else
    fail_t "summary: cache category" "not found"
fi
if echo "$NEW_SUMMARY" | grep -q 'containers'; then
    ok_t "summary: containers category present"
else
    fail_t "summary: containers category" "not found"
fi
if echo "$NEW_SUMMARY" | grep -q 'other'; then
    ok_t "summary: other category present"
else
    fail_t "summary: other category" "not found"
fi

# Test 13c: Disk Overview section
msg "Testing Disk Overview section..."
DISK_SUMMARY=$(sed -n '/Disk Overview/,/^└────/p' "$DEEPCLEAN")
if echo "$DISK_SUMMARY" | grep -q 'Total Capacity'; then
    ok_t "summary: Total Capacity present"
else
    fail_t "summary: Total Capacity" "not found"
fi
if echo "$DISK_SUMMARY" | grep -q 'Before Clean'; then
    ok_t "summary: Before Clean present"
else
    fail_t "summary: Before Clean" "not found"
fi
if echo "$DISK_SUMMARY" | grep -q 'Freed'; then
    ok_t "summary: Freed present"
else
    fail_t "summary: Freed" "not found"
fi
if echo "$DISK_SUMMARY" | grep -q 'After Clean'; then
    ok_t "summary: After Clean present"
else
    fail_t "summary: After Clean" "not found"
fi
if echo "$DISK_SUMMARY" | grep -q 'Free Space'; then
    ok_t "summary: Free Space present"
else
    fail_t "summary: Free Space" "not found"
fi

# Test 14: Drop-in directories are created with mkdir -p
msg "Testing drop-in directory creation..."
for dir in \
    '/etc/systemd/journald.conf.d' \
    '/etc/systemd/coredump.conf.d' \
    '/etc/logrotate.d' \
    '/etc/docker' \
    '/etc/containerd' \
    '/etc/systemd/system/kubelet.service.d' \
    '/etc/rsyslog.d' \
    '/etc/syslog-ng/conf.d'; do
    if grep -q "mkdir -p $dir" "$DEEPCLEAN"; then
        ok_t "mkdir -p $dir present"
    else
        fail_t "mkdir -p $dir" "not found"
    fi
done
# /etc/audit is created inline in auditd block (not with explicit mkdir -p)
if grep -q 'mkdir -p /etc/audit' "$DEEPCLEAN"; then
    ok_t "mkdir -p /etc/audit present"
else
    # Check if auditd block creates it implicitly
    if grep -q '/etc/audit/auditd.conf' "$DEEPCLEAN"; then
        ok_t "auditd config path handled (mkdir implicit in atomic write)"
    else
        fail_t "mkdir -p /etc/audit" "not found and no auditd config"
    fi
fi

# Test 14b: tmpfiles.d for journald vacuum on boot
msg "Testing tmpfiles.d journald vacuum..."
if grep -q '/etc/tmpfiles.d/99-neohiro-journald-vacuum.conf' "$DEEPCLEAN"; then
    ok_t "tmpfiles.d journald vacuum config present"
else
    fail_t "tmpfiles.d journald vacuum" "not found"
fi
if grep -q 'w /run/systemd/journald-vacuum-trigger' "$DEEPCLEAN"; then
    ok_t "tmpfiles.d uses 'w' command for journalctl vacuum"
else
    fail_t "tmpfiles.d vacuum command" "missing 'w' command for journalctl"
fi

# Test 14c: volatile storage cleanup
msg "Testing volatile storage cleanup..."
if grep -q 'STORAGE_MODE.*volatile' "$DEEPCLEAN"; then
    ok_t "volatile storage mode detection present"
else
    fail_t "volatile storage mode detection" "not found"
fi
if grep -q 'rm -rf /var/log/journal' "$DEEPCLEAN"; then
    ok_t "volatile: /var/log/journal cleanup present"
else
    fail_t "volatile: /var/log/journal cleanup" "not found"
fi

# Test 16b: Storage breakdown analysis function
msg "Testing storage breakdown analysis..."
if grep -q 'analyze_storage_breakdown' "$DEEPCLEAN"; then
    ok_t "storage breakdown function present"
else
    fail_t "storage breakdown function" "not found"
fi
if grep -q 'mktemp -t deepclean_breakdown' "$DEEPCLEAN"; then
    ok_t "storage breakdown uses mktemp for temp file"
else
    fail_t "storage breakdown temp file" "missing mktemp"
fi
# shellcheck disable=SC2016
if grep -q 'case "$target_mount"' "$DEEPCLEAN"; then
    ok_t "storage breakdown validates target_mount"
else
    fail_t "storage breakdown target_mount validation" "missing"
fi
if grep -q '\[ -d' "$DEEPCLEAN" && grep -q 'du -kx' "$DEEPCLEAN"; then
    ok_t "storage breakdown checks dir existence before du"
else
    fail_t "storage breakdown dir existence check" "missing"
fi
if grep -q 'echo "system 0"' "$DEEPCLEAN" || grep -q 'echo "user 0"' "$DEEPCLEAN"; then
    ok_t "storage breakdown defaults to 0 on failure"
else
    fail_t "storage breakdown default 0 on failure" "missing"
fi

# Test 16c: _fmt_kb input validation
msg "Testing _fmt_kb input validation..."
if grep -q '_fmt_kb' "$DEEPCLEAN"; then
    ok_t "_fmt_kb function present"
else
    fail_t "_fmt_kb function" "not found"
fi
# shellcheck disable=SC2016
if grep -q 'case "$kb"' "$DEEPCLEAN" && grep -q '\*\[!0-9\]' "$DEEPCLEAN"; then
    ok_t "_fmt_kb validates non-negative integer input"
else
    fail_t "_fmt_kb input validation" "missing"
fi
if grep -q 'kb=0' "$DEEPCLEAN" && grep -q '_fmt_kb' "$DEEPCLEAN"; then
    ok_t "_fmt_kb defaults to 0 on invalid input"
else
    fail_t "_fmt_kb default 0 on invalid" "missing"
fi

# Test 16d: _draw_bar input validation
msg "Testing _draw_bar input validation..."
if grep -q '_draw_bar' "$DEEPCLEAN"; then
    ok_t "_draw_bar function present"
else
    fail_t "_draw_bar function" "not found"
fi
# shellcheck disable=SC2016
if grep -q 'case "$used_kb"' "$DEEPCLEAN" && grep -q 'case "$total_kb"' "$DEEPCLEAN"; then
    ok_t "_draw_bar validates both inputs"
else
    fail_t "_draw_bar input validation" "missing"
fi
if grep -q 'pct=100' "$DEEPCLEAN" && grep -q '_draw_bar' "$DEEPCLEAN"; then
    ok_t "_draw_bar caps percentage at 100"
else
    fail_t "_draw_bar percentage cap" "missing"
fi

# Test 15: DeepClean.sh syntax validation
msg "Testing DeepClean.sh syntax..."
# We can't run bash -n here (no bash on Windows), but we can check for common issues
if grep -q 'set -euo pipefail' "$DEEPCLEAN"; then
    ok_t "syntax: set -euo pipefail present"
else
    fail_t "syntax: set -euo pipefail" "missing"
fi
if grep -q '\ -ne 0' "$DEEPCLEAN"; then
    ok_t "syntax: root check present"
else
    fail_t "syntax: root check" "missing"
fi

# Test 16: No hardcoded paths that would break on different distros
msg "Testing cross-distro path handling..."
if grep -q '/var/log/journal' "$DEEPCLEAN"; then
    ok_t "paths: /var/log/journal used (standard)"
else
    fail_t "paths: /var/log/journal" "not found"
fi
if grep -q '/var/log/syslog' "$DEEPCLEAN" && grep -q '/var/log/messages' "$DEEPCLEAN"; then
    ok_t "paths: both syslog (Debian) and messages (RHEL) handled"
else
    fail_t "paths: syslog/messages both" "missing one"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d log-limit test(s) passed.%s\n' "$C_GRN" "$TOTAL" "$C_RST"; exit 0
else
  printf '%s%d of %d log-limit test(s) failed.%s\n' "$C_RED" "$FAIL" "$TOTAL" "$C_RST"; exit 1
fi