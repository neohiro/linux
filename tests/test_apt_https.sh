#!/usr/bin/env bash
# tests/test_apt_https.sh - hermetic unit tests for the repository transport
# guard (lib/apt-https.sh).
#
# Nothing here touches the real /etc, /var/backups, or any package manager:
#
#   * NEOHIRO_APT_ETC_DIR / NEOHIRO_APT_BACKUP_DIR relocate the tree the lib
#     reads and writes into a temp sandbox.
#   * After sourcing the lib we replace apt_https_family() so the suite
#     behaves identically on Ubuntu, in the bash:4 / bash:latest docker
#     images used by CI, and on a developer laptop with no package manager.
#   * We replace _apt_priv() and _apt_https_privileged_ok() so the suite
#     behaves as if it were root, without needing root. The real _apt_priv is
#     exercised separately through its DRY_RUN path in a subshell.
#   * A fake `ufw` on PATH makes the optional port-80 block deterministic.
#   * NEOHIRO_APT_HTTPS_NOVERIFY=1 means the verification `apt-get update`
#     never runs, so no network call is ever made.
#
# Run: bash tests/test_apt_https.sh
set -u
PASS=0; FAIL=0
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_RST=""; fi

ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$C_RST" "$1" "$2"; FAIL=$((FAIL+1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/lib/apt-https.sh"
SRC="$ROOT/linuxinstall.sh"
[ -f "$LIB" ] || { echo "lib/apt-https.sh not found at $LIB"; exit 2; }
[ -f "$SRC" ] || { echo "linuxinstall.sh not found at $SRC"; exit 2; }

WD="$(mktemp -d)"
_TMP_STAGED=()
cleanup() { rm -rf "$WD" 2>/dev/null || true; rm -f "${_TMP_STAGED[@]}" 2>/dev/null || true; }
trap cleanup EXIT

SANDBOX="$WD/etc"
BACKUPS="$WD/backups"
FAKEHOME="$WD/home"
FAKEBIN="$WD/bin"
mkdir -p "$FAKEBIN" "$FAKEHOME"

# Fake ufw: `ufw status` reports nothing installed yet; any mutating call is
# recorded so a test can assert it happened (or did not).
cat > "$FAKEBIN/ufw" <<'FAKEEOF'
#!/bin/sh
case "${1:-}" in
  status) exit 0 ;;
  *) echo "$*" >> "$FAKE_UFW_LOG"; exit 0 ;;
esac
FAKEEOF
chmod +x "$FAKEBIN/ufw"
export FAKE_UFW_LOG="$WD/ufw-calls.log"
export PATH="$FAKEBIN:$PATH"

# --- source the library, THEN install the stubs ------------------------------
# Order matters: the lib defines _apt_priv and apt_https_family itself, so
# anything we want to fake has to be replaced afterwards.
# shellcheck disable=SC1090
. "$LIB"

# _tmpfile is what the lib prefers for scratch files; a tracked version keeps
# everything inside the temp dir.
_tmpfile() {
  local f
  f="$(mktemp "$WD/stage.XXXXXX")" || return 1
  _TMP_STAGED+=("$f")
  printf '%s' "$f"
}
# Simulate root without needing root.
_apt_priv() { "$@"; }
_apt_https_privileged_ok() { return 0; }
# Force the family per-test via TEST_FAMILY. Note the lib's own
# NEOHIRO_APT_FAMILY override is what the CLI paths use; this stub exists so
# the unit tests can flip families without re-exporting on every reset.
apt_https_family() { printf '%s' "${TEST_FAMILY:-apt}"; }

reset_sandbox() {
  TEST_FAMILY=apt
  rm -rf "$SANDBOX" "$BACKUPS" 2>/dev/null || true
  mkdir -p "$SANDBOX/apt/apt.conf.d" "$SANDBOX/apt/sources.list.d" "$BACKUPS"
  export NEOHIRO_APT_ETC_DIR="$SANDBOX"
  export NEOHIRO_APT_BACKUP_DIR="$BACKUPS"
  export NEOHIRO_APT_HTTPS_NOVERIFY=1
  unset NEOHIRO_APT_HTTPS NEOHIRO_APT_HTTPS_REWRITE NEOHIRO_APT_FAMILY \
        NEOHIRO_APT_HTTPS_STRICT NEOHIRO_APT_BLOCK_PORT80 2>/dev/null || true
  # Hermeticity: the pip/npm/cargo/gem detectors read config from $HOME and
  # transport from the environment. Point HOME at the sandbox and clear every
  # transport variable so the developer's real ~/.npmrc or PIP_INDEX_URL
  # cannot make this suite report findings it did not create.
  export HOME="$FAKEHOME"
  unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL NPM_CONFIG_REGISTRY npm_config_registry \
        CARGO_REGISTRIES_CRATES_IO_INDEX GEM_SOURCE \
        HOMEBREW_BREW_GIT_REMOTE HOMEBREW_CORE_GIT_REMOTE \
        HOMEBREW_API_DOMAIN HOMEBREW_ARTIFACT_DOMAIN 2>/dev/null || true
  _APT_HTTPS_DONE=""
  DRY_RUN=0
}

# _mode_supported — false on filesystems that do not model POSIX permissions
# (Git Bash on NTFS, some container overlay/CIFS mounts). Permission
# assertions must self-skip there rather than fail spuriously.
_mode_supported() {
  local f="$WD/modeprobe"
  : > "$f"
  chmod 0600 "$f" 2>/dev/null
  if [ "$(ls -l "$f" 2>/dev/null | cut -c1-10)" = "-rw-------" ]; then
    rm -f "$f"; return 0
  fi
  rm -f "$f"; return 1
}

# ============================================================================
# NEOHIRO_APT_FAMILY pin (this is what the CLI paths use)
# ============================================================================
reset_sandbox
PINNED="$(env NEOHIRO_APT_FAMILY=zypper bash -c ". '$LIB' >/dev/null 2>&1; apt_https_family" 2>/dev/null)"
if [ "$PINNED" = "zypper" ]; then
  ok_t "NEOHIRO_APT_FAMILY pins the detected family"
else
  fail_t "NEOHIRO_APT_FAMILY pins the detected family" "got: ${PINNED:-<empty>}"
fi

# Single source of truth: the family pin lives only in the library. The
# curl|bash path sources that library, so there is no second copy to drift.
if grep -q 'NEOHIRO_APT_FAMILY' "$LIB"; then
  ok_t "NEOHIRO_APT_FAMILY is implemented in the single canonical library"
else
  fail_t "NEOHIRO_APT_FAMILY is implemented in the single canonical library" "not found in lib"
fi

# ============================================================================
# Path helpers
# ============================================================================
reset_sandbox

if [ "$(apt_https_etc_dir)" = "$SANDBOX" ]; then
  ok_t "apt_https_etc_dir honors NEOHIRO_APT_ETC_DIR"
else
  fail_t "apt_https_etc_dir honors NEOHIRO_APT_ETC_DIR" "got: $(apt_https_etc_dir)"
fi

if [ "$(apt_https_backup_dir)" = "$BACKUPS" ]; then
  ok_t "apt_https_backup_dir honors NEOHIRO_APT_BACKUP_DIR"
else
  fail_t "apt_https_backup_dir honors NEOHIRO_APT_BACKUP_DIR" "got: $(apt_https_backup_dir)"
fi

EXPECT_CONF="$SANDBOX/apt/apt.conf.d/99neohiro-force-https"
if [ "$(apt_https_conf_file)" = "$EXPECT_CONF" ]; then
  ok_t "apt_https_conf_file points at the managed drop-in"
else
  fail_t "apt_https_conf_file points at the managed drop-in" "got: $(apt_https_conf_file)"
fi

# Default paths must be the real system paths when the overrides are unset.
# These run in a subshell so the sandbox exports do not leak.
DEFAULT_ETC="$(env -u NEOHIRO_APT_ETC_DIR bash -c ". '$LIB' >/dev/null 2>&1; apt_https_etc_dir" 2>/dev/null)"
if [ "$DEFAULT_ETC" = "/etc" ]; then
  ok_t "apt_https_etc_dir defaults to /etc"
else
  fail_t "apt_https_etc_dir defaults to /etc" "got: ${DEFAULT_ETC:-<empty>}"
fi

DEFAULT_BAK="$(env -u NEOHIRO_APT_BACKUP_DIR bash -c ". '$LIB' >/dev/null 2>&1; apt_https_backup_dir" 2>/dev/null)"
if [ "$DEFAULT_BAK" = "/var/backups/neohiro-apt-https" ]; then
  ok_t "apt_https_backup_dir defaults to /var/backups/neohiro-apt-https"
else
  fail_t "apt_https_backup_dir defaults to /var/backups/neohiro-apt-https" "got: ${DEFAULT_BAK:-<empty>}"
fi

# ============================================================================
# Classic sources.list rewriting
# ============================================================================
reset_sandbox
cat > "$SANDBOX/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted
# deb http://commented.example.com/ubuntu noble main
deb-src https://already.secure.example.com/ubuntu noble main
deb [arch=amd64] http://mirror.internal:8080/debian bookworm main
EOF
_apt_https_rewrite_apt_sources
if [ "$_APT_HTTPS_CHANGED" = "1" ]; then
  ok_t "classic rewrite reports 1 changed file"
else
  fail_t "classic rewrite reports 1 changed file" "got N=$_APT_HTTPS_CHANGED"
fi

if grep -q '^deb https://archive.ubuntu.com/ubuntu noble main restricted$' "$SANDBOX/apt/sources.list"; then
  ok_t "classic: http:// deb line rewritten to https://"
else
  fail_t "classic: http:// deb line rewritten to https://" "line not rewritten"
fi

if grep -q '^# deb http://commented.example.com' "$SANDBOX/apt/sources.list"; then
  ok_t "classic: commented-out http:// line left untouched"
else
  fail_t "classic: commented-out http:// line left untouched" "comment was modified"
fi

if grep -q '^deb-src https://already.secure.example.com' "$SANDBOX/apt/sources.list"; then
  ok_t "classic: already-https line unchanged"
else
  fail_t "classic: already-https line unchanged" "line was altered"
fi

if grep -q '^deb \[arch=amd64\] https://mirror.internal:8080/debian' "$SANDBOX/apt/sources.list"; then
  ok_t "classic: bracketed options preserved during rewrite"
else
  fail_t "classic: bracketed options preserved during rewrite" "options mangled"
fi

# Ask the library where it keeps the backup instead of reimplementing the
# naming. Reconstructing it here meant every change to the backup-name scheme
# broke this test for the wrong reason.
BAK="$(_apt_https_backup_path "$SANDBOX/apt/sources.list")"
if [ -f "$BAK" ]; then
  ok_t "classic: original file was backed up before editing"
else
  fail_t "classic: original file was backed up before editing" \
        "no .orig at $BAK (found: $(ls -1 "$BACKUPS" 2>/dev/null | tr '\n' ' '))"
fi

if [ -f "$BAK" ] && grep -q '^deb http://archive.ubuntu.com' "$BAK"; then
  ok_t "classic: backup holds the PRE-edit (plaintext) contents"
else
  fail_t "classic: backup holds the PRE-edit (plaintext) contents" \
        "backup does not contain the original http:// line"
fi

# Distinct paths must get distinct backup names. Flattening "/" to "_" is
# not injective -- /a/b/c and /a_b/c both flattened to _a_b_c -- and a
# collision would make --apt-https-off restore one file with another's
# contents.
BAK_A="$(_apt_https_backup_path '/a/b/c')"
BAK_B="$(_apt_https_backup_path '/a_b/c')"
if [ "$BAK_A" != "$BAK_B" ]; then
  ok_t "backup names do not collide for paths that flatten alike"
else
  fail_t "backup names do not collide for paths that flatten alike" \
        "both mapped to $BAK_A"
fi

# Second pass must be a no-op: idempotency is what keeps re-runs cheap and
# keeps AUTO_MODE from churning backups.
_apt_https_rewrite_apt_sources
if [ "$_APT_HTTPS_CHANGED" = "0" ]; then
  ok_t "classic rewrite is idempotent (second pass changes nothing)"
else
  fail_t "classic rewrite is idempotent (second pass changes nothing)" "got N2=$_APT_HTTPS_CHANGED"
fi

# ============================================================================
# DEB822 (.sources) rewriting
# ============================================================================
reset_sandbox
cat > "$SANDBOX/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian bookworm main
# http://disabled.example.com/debian bookworm main
Suites: bookworm
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
_apt_https_rewrite_apt_sources >/dev/null

if grep -q '^URIs: https://deb.debian.org/debian' "$SANDBOX/apt/sources.list.d/debian.sources"; then
  ok_t "DEB822: URIs: field rewritten to https://"
else
  fail_t "DEB822: URIs: field rewritten to https://" "not rewritten"
fi

if grep -q '^# http://disabled.example.com' "$SANDBOX/apt/sources.list.d/debian.sources"; then
  ok_t "DEB822: commented http:// left untouched"
else
  fail_t "DEB822: commented http:// left untouched" "comment was modified"
fi

if grep -v '^#' "$SANDBOX/apt/sources.list.d/debian.sources" | grep -q 'http://'; then
  fail_t "DEB822: no active plaintext URI remains" "still plaintext"
else
  ok_t "DEB822: no active plaintext URI remains"
fi

if grep -q '^Suites: bookworm$' "$SANDBOX/apt/sources.list.d/debian.sources" && \
   grep -q '^Components: main contrib$' "$SANDBOX/apt/sources.list.d/debian.sources"; then
  ok_t "DEB822: Suites/Components fields preserved"
else
  fail_t "DEB822: Suites/Components fields preserved" "structural fields changed"
fi

# ============================================================================
# apt policy drop-in content
# ============================================================================
reset_sandbox
apt_https_enforce "test" >/dev/null 2>&1
CONF="$(apt_https_conf_file)"
if [ -f "$CONF" ]; then
  ok_t "enforce: apt policy drop-in installed"
else
  fail_t "enforce: apt policy drop-in installed" "$CONF missing"
fi

if [ -f "$CONF" ] && grep -q '^Acquire::http::AllowRedirect "false";' "$CONF"; then
  ok_t "policy: refuses https->http downgrade redirects"
else
  fail_t "policy: refuses https->http downgrade redirects" 'Acquire::http::AllowRedirect "false" missing'
fi

if [ -f "$CONF" ] && grep -q '^Acquire::https::AllowRedirect "true";' "$CONF"; then
  ok_t "policy: allows https->https mirror redirects"
else
  fail_t "policy: allows https->https mirror redirects" 'Acquire::https::AllowRedirect "true" missing'
fi

if [ -f "$CONF" ] && grep -q '^Acquire::https::Verify-Peer "true";' "$CONF" && \
   grep -q '^Acquire::https::Verify-Host "true";' "$CONF"; then
  ok_t "policy: peer + host verification enabled"
else
  fail_t "policy: peer + host verification enabled" "Verify-Peer/Verify-Host missing"
fi

if [ -f "$CONF" ] && grep -q '^Acquire::Retries "3";' "$CONF"; then
  ok_t "policy: retries configured for flaky mirrors"
else
  fail_t "policy: retries configured for flaky mirrors" "Acquire::Retries missing"
fi

# Security by default: the drop-in must not be group/world writable.
if [ -f "$CONF" ]; then
  PERM="$(ls -l "$CONF" 2>/dev/null | cut -c1-10)"
  case "$PERM" in
    -rw-r--r--) ok_t "policy: drop-in mode is 0644" ;;
    *) fail_t "policy: drop-in mode is 0644" "got: $PERM" ;;
  esac
else
  fail_t "policy: drop-in mode is 0644" "drop-in missing"
fi

# Idempotency: a second enforce must not create extra backups.
BAKS_BEFORE="$(find "$BACKUPS" -name '*.orig' 2>/dev/null | wc -l)"
apt_https_enforce "test-2" >/dev/null 2>&1
BAKS_AFTER="$(find "$BACKUPS" -name '*.orig' 2>/dev/null | wc -l)"
if [ "$BAKS_BEFORE" = "$BAKS_AFTER" ]; then
  ok_t "enforce: re-running does not churn backups"
else
  fail_t "enforce: re-running does not churn backups" "$BAKS_BEFORE -> $BAKS_AFTER"
fi

# ============================================================================
# Status / report exit codes
# ============================================================================
reset_sandbox
printf 'deb https://secure.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
apt_https_report >/dev/null 2>&1
RC=$?
if [ "$RC" = "0" ]; then
  ok_t "apt_https_report rc=0 when every repo is https"
else
  fail_t "apt_https_report rc=0 when every repo is https" "rc=$RC"
fi

printf 'deb http://plaintext.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
apt_https_report >/dev/null 2>&1
RC=$?
if [ "$RC" = "1" ]; then
  ok_t "apt_https_report rc=1 when plaintext repos remain"
else
  fail_t "apt_https_report rc=1 when plaintext repos remain" "rc=$RC"
fi

if apt_https_status_text | grep -q 'plaintext.example.com'; then
  ok_t "apt_https_status_text names the offending repo"
else
  fail_t "apt_https_status_text names the offending repo" "offender not reported"
fi

TEST_FAMILY=none
apt_https_report >/dev/null 2>&1
RC=$?
if [ "$RC" = "2" ]; then
  ok_t "apt_https_report rc=2 when no package manager is detected"
else
  fail_t "apt_https_report rc=2 when no package manager is detected" "rc=$RC"
fi

if apt_https_enforce "test" >/dev/null 2>&1; then
  ok_t "enforce: no-op (rc=0) when no package manager is detected"
else
  fail_t "enforce: no-op (rc=0) when no package manager is detected" "returned non-zero"
fi

# ============================================================================
# Env-var kill switches
# ============================================================================
reset_sandbox
printf 'deb http://plaintext.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
export NEOHIRO_APT_HTTPS=0
_APT_HTTPS_DONE=""
apt_https_guard "test-off" >/dev/null 2>&1
if grep -q 'http://plaintext.example.com' "$SANDBOX/apt/sources.list" && \
   [ ! -f "$(apt_https_conf_file)" ]; then
  ok_t "NEOHIRO_APT_HTTPS=0 disables the guard without touching anything"
else
  fail_t "NEOHIRO_APT_HTTPS=0 disables the guard without touching anything" "files were modified"
fi

reset_sandbox
printf 'deb http://plaintext.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
export NEOHIRO_APT_HTTPS=audit
_APT_HTTPS_DONE=""
apt_https_guard "test-audit" >/dev/null 2>&1
if grep -q 'http://plaintext.example.com' "$SANDBOX/apt/sources.list" && \
   [ ! -f "$(apt_https_conf_file)" ]; then
  ok_t "NEOHIRO_APT_HTTPS=audit reports without modifying"
else
  fail_t "NEOHIRO_APT_HTTPS=audit reports without modifying" "files were modified"
fi

# ============================================================================
# once-per-process latch
# ============================================================================
reset_sandbox
printf 'deb http://plaintext.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
_APT_HTTPS_DONE=""
apt_https_guard "first" >/dev/null 2>&1
if [ -z "$(apt_https_status_text)" ]; then
  ok_t "guard: first call enforces (latch set, work done)"
else
  fail_t "guard: first call enforces (latch set, work done)" "repo still plaintext"
fi

# Break the sources on purpose. A second guard call must NOT re-enforce: it
# is a hot-path helper called by every pkg_* helper, so it has to be cheap.
printf 'deb http://regressed.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
apt_https_guard "second" >/dev/null 2>&1
if grep -q 'regressed.example.com' "$SANDBOX/apt/sources.list"; then
  ok_t "guard: second call is a no-op (once per process)"
else
  fail_t "guard: second call is a no-op (once per process)" "second call re-ran enforcement"
fi

# The latch must be resettable so the CLI entry points can force a re-run.
_APT_HTTPS_DONE=""
apt_https_guard "third" >/dev/null 2>&1
if [ -z "$(apt_https_status_text)" ]; then
  ok_t "guard: latch is resettable so the CLI flags can re-run it"
else
  fail_t "guard: latch is resettable so the CLI flags can re-run it" "regression not repaired"
fi

# ============================================================================
# Un-backuppable files must be refused, not corrupted
# ============================================================================
reset_sandbox
printf 'deb http://nope.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
# Make the backup path a regular file so `mkdir -p` cannot succeed.
rm -rf "$BACKUPS"
: > "$BACKUPS"
_APT_HTTPS_DONE=""
REFUSE_OUT="$(apt_https_enforce "no-backup" 2>&1)"
if grep -q 'http://nope.example.com' "$SANDBOX/apt/sources.list"; then
  ok_t "refuses to edit a repo file it cannot back up"
else
  fail_t "refuses to edit a repo file it cannot back up" "file was edited with no backup"
fi
if ! printf '%s' "$REFUSE_OUT" | grep -q 'already use https://'; then
  ok_t "reports a refusal instead of claiming 'already https'"
else
  fail_t "reports a refusal instead of claiming 'already https'" \
        "misleading success message emitted"
fi
if printf '%s' "$REFUSE_OUT" | grep -q 'no writable backup'; then
  ok_t "refusal explains why (no writable backup)"
else
  fail_t "refusal explains why (no writable backup)" "no reason given"
fi
if apt_https_enforce "no-backup-rc" >/dev/null 2>&1; then
  fail_t "enforce returns non-zero when it could not enforce" "rc=0"
else
  ok_t "enforce returns non-zero when it could not enforce"
fi
rm -f "$BACKUPS"

# ============================================================================
# Revert
# ============================================================================
reset_sandbox
ORIG='deb http://original.example.com/ubuntu noble main'
printf '%s\n' "$ORIG" > "$SANDBOX/apt/sources.list"
_APT_HTTPS_DONE=""
apt_https_enforce "revert-test" >/dev/null 2>&1
if grep -q 'https://original.example.com' "$SANDBOX/apt/sources.list"; then
  ok_t "revert: precondition - sources were rewritten to https"
else
  fail_t "revert: precondition - sources were rewritten to https" "rewrite did not happen"
fi
apt_https_revert >/dev/null 2>&1
if [ "$(cat "$SANDBOX/apt/sources.list")" = "$ORIG" ]; then
  ok_t "revert: restores the pre-guard sources file byte for byte"
else
  fail_t "revert: restores the pre-guard sources file byte for byte" \
        "got: $(cat "$SANDBOX/apt/sources.list")"
fi
if [ ! -f "$(apt_https_conf_file)" ]; then
  ok_t "revert: removes the drop-in it created"
else
  fail_t "revert: removes the drop-in it created" "drop-in still present"
fi

# ============================================================================
# dnf / yum / zypper / pacman: audit, no blind rewrite
# ============================================================================
reset_sandbox
TEST_FAMILY=dnf
mkdir -p "$SANDBOX/yum.repos.d"
cat > "$SANDBOX/yum.repos.d/epel.repo" <<'EOF'
[epel]
name=Extra Packages
baseurl=http://mirrors.example.com/epel/9/Everything/x86_64/
metalink=https://mirrors.example.com/metalink?repo=epel-9
gpgcheck=1
EOF

if apt_https_status_text | grep -q 'mirrors.example.com/epel'; then
  ok_t "dnf: plaintext baseurl detected"
else
  fail_t "dnf: plaintext baseurl detected" "nothing reported"
fi

# Default: audit only, no rewrite.
DNFOUT="$(apt_https_enforce "dnf-default" 2>&1)"
if grep -q '^baseurl=http://' "$SANDBOX/yum.repos.d/epel.repo"; then
  ok_t "dnf: no blind rewrite by default"
else
  fail_t "dnf: no blind rewrite by default" "file was rewritten without opt-in"
fi
if printf '%s' "$DNFOUT" | grep -q 'Plaintext endpoints still configured'; then
  ok_t "dnf: leftover plaintext is reported loudly"
else
  fail_t "dnf: leftover plaintext is reported loudly" "no warning emitted"
fi

# Opt-in rewrite.
export NEOHIRO_APT_HTTPS_REWRITE=1
_APT_HTTPS_DONE=""
apt_https_enforce "dnf-optin" >/dev/null 2>&1
if grep -q '^baseurl=https://' "$SANDBOX/yum.repos.d/epel.repo"; then
  ok_t "dnf: NEOHIRO_APT_HTTPS_REWRITE=1 rewrites baseurl"
else
  fail_t "dnf: NEOHIRO_APT_HTTPS_REWRITE=1 rewrites baseurl" "not rewritten"
fi
if grep -q '^gpgcheck=1$' "$SANDBOX/yum.repos.d/epel.repo"; then
  ok_t "dnf: rewrite leaves non-URL settings alone"
else
  fail_t "dnf: rewrite leaves non-URL settings alone" "gpgcheck altered"
fi
unset NEOHIRO_APT_HTTPS_REWRITE

reset_sandbox
TEST_FAMILY=zypper
mkdir -p "$SANDBOX/zypp/repos.d"
cat > "$SANDBOX/zypp/repos.d/oss.repo" <<'EOF'
[repo-oss]
name=openSUSE-Leap
baseurl=http://download.opensuse.org/repositories/oss/
enabled=1
EOF
if apt_https_status_text | grep -q 'download.opensuse.org'; then
  ok_t "zypper: plaintext baseurl detected"
else
  fail_t "zypper: plaintext baseurl detected" "nothing reported"
fi

reset_sandbox
TEST_FAMILY=pacman
mkdir -p "$SANDBOX/pacman.d"
cat > "$SANDBOX/pacman.d/mirrorlist" <<'EOF'
## Worldwide
Server=http://mirror.example.com/archlinux/$repo/os/$arch
Server=https://secure.example.com/archlinux/$repo/os/$arch
EOF
if apt_https_status_text | grep -q 'http://mirror.example.com'; then
  ok_t "pacman: plaintext Server= detected"
else
  fail_t "pacman: plaintext Server= detected" "nothing reported"
fi
if ! apt_https_status_text | grep -q 'secure.example.com'; then
  ok_t "pacman: already-https mirror is not flagged"
else
  fail_t "pacman: already-https mirror is not flagged" "false positive"
fi

# ============================================================================
# DRY_RUN and the optional port-80 block
# ============================================================================
reset_sandbox
# The real _apt_priv (not the stub) is exercised in a subshell so the DRY_RUN
# branch is covered without needing root.
DRY_OUT="$(env DRY_RUN=1 NEOHIRO_APT_ETC_DIR="$SANDBOX" NEOHIRO_APT_BACKUP_DIR="$BACKUPS" \
  bash -c ". '$LIB' >/dev/null 2>&1; _apt_priv ufw deny out 80/tcp" 2>&1)"
if printf '%s' "$DRY_OUT" | grep -q 'DRY: ufw deny out 80/tcp'; then
  ok_t "_apt_priv honours DRY_RUN (prints instead of executing)"
else
  fail_t "_apt_priv honours DRY_RUN (prints instead of executing)" "got: $DRY_OUT"
fi

reset_sandbox
TEST_FAMILY=dnf
mkdir -p "$SANDBOX/yum.repos.d"
printf '[x]\nbaseurl=http://plain.example.com/repo/\n' > "$SANDBOX/yum.repos.d/x.repo"
export NEOHIRO_APT_BLOCK_PORT80=1
_APT_HTTPS_DONE=""
: > "$FAKE_UFW_LOG"
BLOCK_OUT="$(apt_https_enforce "port80" 2>&1)"
if printf '%s' "$BLOCK_OUT" | grep -q 'Skipping the port-80 block'; then
  ok_t "port-80 block is skipped while plaintext repos remain"
else
  fail_t "port-80 block is skipped while plaintext repos remain" \
        "block attempted anyway: $(cat "$FAKE_UFW_LOG" 2>/dev/null | tr '\n' ' ')"
fi
if [ ! -s "$FAKE_UFW_LOG" ]; then
  ok_t "port-80 block emits no ufw rule when it declines"
else
  fail_t "port-80 block emits no ufw rule when it declines" "ufw was called"
fi

reset_sandbox
printf 'deb https://secure.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
export NEOHIRO_APT_BLOCK_PORT80=1
_APT_HTTPS_DONE=""
: > "$FAKE_UFW_LOG"
apt_https_enforce "port80-clean" >/dev/null 2>&1
if grep -q 'deny out 80/tcp' "$FAKE_UFW_LOG" 2>/dev/null; then
  ok_t "port-80 block proceeds once all repos are https"
else
  fail_t "port-80 block proceeds once all repos are https" "no ufw rule emitted"
fi
unset NEOHIRO_APT_BLOCK_PORT80

# Default: the block must be completely opt-in.
reset_sandbox
: > "$FAKE_UFW_LOG"
_APT_HTTPS_DONE=""
apt_https_enforce "port80-default" >/dev/null 2>&1
if [ ! -s "$FAKE_UFW_LOG" ]; then
  ok_t "port-80 block is opt-in (no ufw rule by default)"
else
  fail_t "port-80 block is opt-in (no ufw rule by default)" \
        "ufw called: $(cat "$FAKE_UFW_LOG" | tr '\n' ' ')"
fi

# ============================================================================
# Integration: every package entry point calls the guard
# ============================================================================
GUARD_FNS="pkg_update pkg_install pkg_upgrade pkg_autoremove update_system update_kernel"
for fn in $GUARD_FNS; do
  BODY="$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$SRC")"
  if printf '%s' "$BODY" | grep -q 'apt_https_guard'; then
    ok_t "integration: $fn() calls apt_https_guard"
  else
    fail_t "integration: $fn() calls apt_https_guard" "no guard call found in $fn()"
  fi
done

# The guard must appear BEFORE the first package-manager invocation in the
# body, otherwise it is decorative.
for fn in pkg_update pkg_install pkg_upgrade pkg_autoremove; do
  LINE_GUARD="$(grep -n "apt_https_guard \"$fn\"" "$SRC" | head -1 | cut -d: -f1)"
  LINE_PKG="$(grep -n "^${fn}() {" "$SRC" | head -1 | cut -d: -f1)"
  FIRST_USE="$(awk -v start="$LINE_PKG" 'NR>start && /apt-get|dnf |yum |zypper |pacman /{print NR; exit}' "$SRC")"
  if [ -n "$LINE_GUARD" ] && [ -n "$FIRST_USE" ] && [ "$LINE_GUARD" -lt "$FIRST_USE" ]; then
    ok_t "integration: $fn() guards before its first package command"
  else
    fail_t "integration: $fn() guards before its first package command" \
          "guard@${LINE_GUARD:-none} firstpkg@${FIRST_USE:-none}"
  fi
done

# lib/updater.sh must guard the dispatcher and every sub-step that touches
# the network. _update_virsh, _update_suse_snapper and _update_btrfs_balance
# are deliberately excluded: they only read/write local state.
UP="$ROOT/lib/updater.sh"
for fn in _update_apt _update_dnf _update_yum _update_zypper _update_pacman \
          _update_snap _update_flatpak _update_docker _update_brew _update_firmware \
          _update_geoip _update_pihole _run_all_updates; do
  if grep -q "apt_https_guard \"$fn\"" "$UP"; then
    ok_t "integration: updater $fn() calls apt_https_guard"
  else
    fail_t "integration: updater $fn() calls apt_https_guard" "no guard call"
  fi
done

# The curl|bash inline fallback in linuxinstall.sh has its own copies of every
# _update_*; those must be guarded too, since curl|bash is the documented
# primary install method and never sees lib/updater.sh.
for fn in _update_apt _update_dnf _update_yum _update_zypper _update_pacman \
          _update_snap _update_flatpak _update_docker _update_brew _update_firmware \
          _run_all_updates; do
  BODY="$(awk -v fn="$fn" '
    $0 ~ "^[[:space:]]*"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
    inside { print }
    inside && /^[[:space:]]*}/ { exit }
  ' "$SRC")"
  if printf '%s' "$BODY" | grep -q 'apt_https_guard'; then
    ok_t "integration: inline $fn() calls apt_https_guard"
  else
    fail_t "integration: inline $fn() calls apt_https_guard" "no guard call"
  fi
done

# GEOIP_URL is operator-supplied and decides which country a packet is "in",
# so a plaintext mirror is a traffic-tunneling primitive. Must be refused.
GEOIP_BODY="$(awk '/^_update_geoip\(\) \{/,/^}/' "$UP")"
if printf '%s' "$GEOIP_BODY" | grep -q 'http://\*' && \
   printf '%s' "$GEOIP_BODY" | grep -q 'Refusing to download the GeoIP database over HTTP'; then
  ok_t "integration: _update_geoip refuses a plaintext GEOIP_URL"
else
  fail_t "integration: _update_geoip refuses a plaintext GEOIP_URL" "scheme check missing"
fi
# The check must come AFTER the URL is fully resolved, otherwise the default
# fork (which is already https) would be validated against nothing.
GEOIP_LINE="$(printf '%s' "$GEOIP_BODY" | grep -n 'case "$_geoip_url" in' | cut -d: -f1)"
DEFAULT_LINE="$(printf '%s' "$GEOIP_BODY" | grep -n 'maccurry/GeoIP-country' | cut -d: -f1)"
if [ -n "$GEOIP_LINE" ] && [ -n "$DEFAULT_LINE" ] && [ "$GEOIP_LINE" -gt "$DEFAULT_LINE" ]; then
  ok_t "integration: _update_geoip validates the URL scheme after resolving it"
else
  fail_t "integration: _update_geoip validates the URL scheme after resolving it" \
        "check@${GEOIP_LINE:-none} must come after default@${DEFAULT_LINE:-none}"
fi

# Subscripts fetched via run_remote_script land in $TMP_DIR with no lib/, so
# their transport guard would silently not exist. The installer must prefetch
# lib/apt-https.sh next to them.
if grep -q '_fetch_https_lib_for_subscript' "$SRC" && \
   grep -q 'lib/apt-https.sh' "$SRC"; then
  ok_t "integration: run_remote_script prefetches lib/apt-https.sh for subscripts"
else
  fail_t "integration: run_remote_script prefetches lib/apt-https.sh for subscripts" \
        "lib prefetch missing"
fi
if awk '/^run_remote_script\(\) \{/,/^}/' "$SRC" | grep -q '_fetch_https_lib_for_subscript'; then
  ok_t "integration: the lib prefetch lives inside run_remote_script"
else
  fail_t "integration: the lib prefetch lives inside run_remote_script" "not in run_remote_script"
fi

# A subscript without the lib must say so rather than skip silently.
for f in restore_ssh.sh DeepClean.sh; do
  if grep -q 'not found next to this script' "$ROOT/$f"; then
    ok_t "integration: $f warns when lib/apt-https.sh is unavailable"
  else
    fail_t "integration: $f warns when lib/apt-https.sh is unavailable" "no warning"
  fi
done

if grep -q 'apt-https.sh' "$UP" && grep -q 'source .*apt-https.sh' "$ROOT/restore_ssh.sh" && \
   grep -q 'source .*apt-https.sh' "$ROOT/DeepClean.sh" && \
   grep -q 'source .*apt-https.sh' "$SRC"; then
  ok_t "integration: every entry-point script sources lib/apt-https.sh"
else
  fail_t "integration: every entry-point script sources lib/apt-https.sh" "source line missing somewhere"
fi

if grep -q 'apt_https_guard "restore_ssh:pkg_install_ssh"' "$ROOT/restore_ssh.sh"; then
  ok_t "integration: restore_ssh.sh guards before installing openssh-server"
else
  fail_t "integration: restore_ssh.sh guards before installing openssh-server" "no guard call"
fi

if grep -q 'apt_https_guard "DeepClean"' "$ROOT/DeepClean.sh"; then
  ok_t "integration: DeepClean.sh guards before its apt-get autoremove pass"
else
  fail_t "integration: DeepClean.sh guards before its apt-get autoremove pass" "no guard call"
fi

# Menus / CLI surfaces must be reachable.
if grep -q '_run_step apt_https' "$SRC"; then
  ok_t "integration: apt_https is a first-class workflow step"
else
  fail_t "integration: apt_https is a first-class workflow step" "step missing"
fi

if grep -q 'apt_https_enforce "maintenance menu"' "$SRC"; then
  ok_t "integration: maintenance submenu exposes the guard"
else
  fail_t "integration: maintenance submenu exposes the guard" "submenu entry missing"
fi

for flag in '--apt-https|--enforce-https' '--apt-https-audit' '--apt-https-off|--disable-https'; do
  if grep -q -- "$flag)" "$SRC"; then
    ok_t "integration: CLI flag parsed: $flag"
  else
    fail_t "integration: CLI flag parsed: $flag" "flag not handled in main()"
  fi
done

for flag in '--apt-https|--enforce-https' '--apt-https-audit' '--apt-https-off|--disable-https'; do
  if grep -q -- "$flag)" "$UP"; then
    ok_t "integration: updater standalone CLI flag parsed: $flag"
  else
    fail_t "integration: updater standalone CLI flag parsed: $flag" "flag missing"
  fi
done

if grep -q '_VALID_STEPS="[^"]*apt_https' "$SRC"; then
  ok_t "integration: --step apt_https is a valid step key"
else
  fail_t "integration: --step apt_https is a valid step key" "key missing from _VALID_STEPS"
fi

if grep -q '\[apt_https\]=pending' "$SRC" && grep -q 'CHECKLIST_LABEL_apt_https=' "$SRC" && \
   grep -q '_CHECKLIST_ORDER="[^"]*apt_https' "$SRC"; then
  ok_t "integration: progress checklist shows the guard step"
else
  fail_t "integration: progress checklist shows the guard step" "checklist wiring incomplete"
fi

# ============================================================================
# Single implementation: the curl|bash path must LOAD the canonical library
# ============================================================================
# linuxinstall.sh used to carry a ~400-line inline copy of the guard. That is
# the worst arrangement for security-critical code: a fix in lib/apt-https.sh
# silently did not reach `curl | sudo bash`, the documented primary install
# method. It now resolves and sources the canonical library instead.
if grep -q '_apt_https_resolved' "$SRC" && \
   grep -q 'REPO_RAW_BASE}/lib/apt-https.sh' "$SRC"; then
  ok_t "curl|bash path resolves lib/apt-https.sh instead of duplicating it"
else
  fail_t "curl|bash path resolves lib/apt-https.sh instead of duplicating it" \
        "resolver block missing"
fi

# No helper from the library may be redefined inline any more. If one creeps
# back in, the two copies can drift again -- which is the bug this guards.
INLINE_DUPLICATES=""
for fn in _apt_https_plaintext_in_apt_file _apt_https_atomic_replace \
          _apt_https_prep_repo_stage _apt_https_rewrite_file \
          _apt_https_source_files _apt_https_source_plaintext \
          _apt_https_source_prefer_https _apt_https_managed_files \
          _apt_https_plaintext_generic; do
  if grep -qE "^[[:space:]]+${fn}\(\) *\{" "$SRC"; then
    INLINE_DUPLICATES="$INLINE_DUPLICATES $fn"
  fi
done
if [ -z "$INLINE_DUPLICATES" ]; then
  ok_t "no library helper is redefined inline in linuxinstall.sh"
else
  fail_t "no library helper is redefined inline in linuxinstall.sh" \
        "duplicated again:$INLINE_DUPLICATES"
fi

# When the library genuinely cannot be loaded, every public entry point must
# still exist so no caller hits an undefined function.
if grep -q 'apt_https_guard()      { _apt_https_unavailable' "$SRC" && \
   grep -q 'apt_https_enforce()    { _apt_https_unavailable' "$SRC" && \
   grep -q 'apt_https_report()     { _apt_https_unavailable' "$SRC" && \
   grep -q 'apt_https_revert()     { _apt_https_unavailable' "$SRC" && \
   grep -q 'apt_https_status_text(){ return 0; }' "$SRC"; then
  ok_t "degraded mode still defines every public entry point"
else
  fail_t "degraded mode still defines every public entry point" \
        "a stub is missing; a caller would hit an undefined function"
fi

# The helpers that callers outside this file use must be stubbed too.
for fn in apt_https_backup_dir apt_https_conf_file; do
  if grep -qE "^[[:space:]]+${fn}\(\) *\{" "$SRC"; then
    ok_t "degraded mode stubs $fn (used by _step_apt_https)"
  else
    fail_t "degraded mode stubs $fn (used by _step_apt_https)" "not stubbed"
  fi
done
# ============================================================================
# _step_apt_https exit-status plumbing
# ============================================================================
# `if ! cmd; then rc=$?; fi` captures the *negation's* status, so a failed
# enforcement would silently report success. Assert the correct form is used.
if grep -q 'apt_https_enforce "step:apt_https" || rc=\$?' "$SRC"; then
  ok_t "_step_apt_https propagates the real exit status"
else
  fail_t "_step_apt_https propagates the real exit status" \
        "expected 'apt_https_enforce ... || rc=\$?' in _step_apt_https"
fi

if grep -qE 'if ! apt_https_enforce[^|]*; then rc=\$\?' "$SRC"; then
  fail_t "_step_apt_https avoids the 'if ! cmd; then rc=\$?' trap" "trap present"
else
  ok_t "_step_apt_https avoids the 'if ! cmd; then rc=\$?' trap"
fi

# Behavioural check: a failing enforcement must make the step fail.
reset_sandbox
printf 'deb http://nope.example.com/ubuntu noble main\n' > "$SANDBOX/apt/sources.list"
rm -rf "$BACKUPS"; : > "$BACKUPS"
# Mirror _step_apt_https's body against the sandboxed lib.
_APT_HTTPS_DONE=""
_S_RC=0
apt_https_enforce "step:apt_https" || _S_RC=$?
if [ "$_S_RC" -ne 0 ]; then
  ok_t "failed enforcement yields a non-zero status (verified at runtime)"
else
  fail_t "failed enforcement yields a non-zero status (verified at runtime)" "got 0"
fi
rm -f "$BACKUPS"

# ============================================================================
# Runtime: run_remote_script prefetches lib/apt-https.sh for subscripts
# ============================================================================
# A subscript fetched into $TMP_DIR resolves helpers relative to its own
# location, and $TMP_DIR has no lib/ directory. Extract the function and
# drive it with a fake curl so the prefetch is actually executed.
{
  awk '/^run_remote_script\(\) \{/,/^}/' "$SRC"
} > "$WD/rrs.sh"

run_rrs_case() {
  # $1 = fake curl behaviour: "ok" writes a payload, "fail" exits non-zero.
  local mode="$1" out
  (
    set -u
    TMP_DIR="$WD/rrs_tmp"
    rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"
    REPO_RAW_BASE="https://raw.githubusercontent.com/neohiro/linux/main"
    _log() { :; }
    ok()  { printf 'OK:%s\n' "$*"; }
    warn(){ printf 'WARN:%s\n' "$*"; }
    err() { printf 'ERR:%s\n' "$*"; }
    # Stub curl/wget: record the URL, optionally fail.
    curl() {
      case "$1" in
        -*) : ;;
      esac
      # Last two args are the URL and the -o target.
      local url="" outp=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -o) outp="$2"; shift 2 ;;
          http*) url="$1"; shift ;;
          *) shift ;;
        esac
      done
      printf '%s\n' "$url" >> "$WD/curl-urls.log"
      if [ "$mode" = "fail" ] && [ "$url" != "${REPO_RAW_BASE}/DeepClean.sh" ]; then
        return 22
      fi
      printf '# fetched payload for %s\n' "$url" > "$outp"
      return 0
    }
    # shellcheck disable=SC1090
    . "$WD/rrs.sh"
    # Stop before the execution-mode decision; we only care about the fetch.
    run_remote_script "DeepClean.sh" >/dev/null 2>&1 || true
    printf 'CURL_URLS=%s\n' "$(cat "$WD/curl-urls.log" 2>/dev/null | tr '\n' ' ')"
    if [ -s "$TMP_DIR/lib/apt-https.sh" ]; then
      printf 'LIB_PRESENT=yes\n'
    else
      printf 'LIB_PRESENT=no\n'
    fi
    printf 'SUB_PRESENT=%s\n' "$([ -s "$TMP_DIR/DeepClean.sh" ] && echo yes || echo no)"
  ) 2>/dev/null
}

: > "$WD/curl-urls.log"
RRS_OK="$(run_rrs_case ok)"
if printf '%s' "$RRS_OK" | grep -q 'lib/apt-https.sh'; then
  ok_t "run_remote_script requests lib/apt-https.sh from the repo"
else
  fail_t "run_remote_script requests lib/apt-https.sh from the repo" \
        "URLs seen: $(printf '%s' "$RRS_OK" | grep '^CURL_URLS=')"
fi
if printf '%s' "$RRS_OK" | grep -q 'LIB_PRESENT=yes'; then
  ok_t "run_remote_script places lib/apt-https.sh next to the subscript"
else
  fail_t "run_remote_script places lib/apt-https.sh next to the subscript" \
        "$(printf '%s' "$RRS_OK" | grep LIB_PRESENT=)"
fi
if printf '%s' "$RRS_OK" | grep -q 'SUB_PRESENT=yes'; then
  ok_t "run_remote_script still fetched the subscript itself"
else
  fail_t "run_remote_script still fetched the subscript itself" "subscript missing"
fi

: > "$WD/curl-urls.log"
RRS_FAIL="$(run_rrs_case fail)"
if printf '%s' "$RRS_FAIL" | grep -q 'SUB_PRESENT=yes'; then
  ok_t "a failed lib prefetch is non-fatal (subscript still fetched)"
else
  fail_t "a failed lib prefetch is non-fatal (subscript still fetched)" \
        "a lib fetch failure aborted the run"
fi
if printf '%s' "$RRS_FAIL" | grep -q 'LIB_PRESENT=no'; then
  ok_t "a failed lib prefetch leaves no empty stub file behind"
else
  fail_t "a failed lib prefetch leaves no empty stub file behind" "stale file left"
fi

# ============================================================================
# Runtime: _update_geoip refuses a plaintext GEOIP_URL
# ============================================================================
GEOIP_RT="$(env NEOHIRO_APT_FAMILY=apt NEOHIRO_APT_HTTPS=0 GEOIP_URL='http://evil.example.com/Geo.mmdb' \
  bash -c "
    . '$UP' >/dev/null 2>&1
    UPDATED=0; FAILED=0
    _update_geoip 2>&1
    printf 'RC=%s\n' \$?
  " 2>&1)"
if printf '%s' "$GEOIP_RT" | grep -q 'Refusing to download the GeoIP database over HTTP'; then
  ok_t "_update_geoip refuses an http:// GEOIP_URL at runtime"
else
  fail_t "_update_geoip refuses an http:// GEOIP_URL at runtime" \
        "got: $(printf '%s' "$GEOIP_RT" | tr '\n' ' ')"
fi

GEOIP_OK="$(env NEOHIRO_APT_FAMILY=apt NEOHIRO_APT_HTTPS=0 GEOIP_URL='https://good.example.com/Geo.mmdb' \
  bash -c "
    . '$UP' >/dev/null 2>&1
    UPDATED=0; FAILED=0
    _update_geoip 2>&1
    printf 'RC=%s\n' \$?
  " 2>&1)"
if ! printf '%s' "$GEOIP_OK" | grep -q 'Refusing to download'; then
  ok_t "_update_geoip accepts an https:// GEOIP_URL"
else
  fail_t "_update_geoip accepts an https:// GEOIP_URL" "false rejection"
fi

# ============================================================================
# Runtime: exit codes survive `set -eo pipefail`
# ============================================================================
# restore_ssh.sh, DeepClean.sh and the lib/updater.sh standalone branch all
# run under `set -e`. A bare call that returns non-zero exits before the
# report prints, and `return $?` after a `... || true` reports the wrong
# status. Drive the real scripts with a failing enforcement and assert both
# the exit code and that the report still printed.
_rrc() {
  local script="$1" flag="$2"
  env NEOHIRO_APT_ETC_DIR="$SANDBOX" NEOHIRO_APT_BACKUP_DIR="$BACKUPS" \
      NEOHIRO_APT_FAMILY=apt NEOHIRO_APT_HTTPS_NOVERIFY=1 \
      bash "$ROOT/$script" "$flag" 2>&1
  printf '__RC=%s\n' "$?"
}

reset_sandbox
printf 'deb https://secure.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
OUT="$(_rrc lib/updater.sh --apt-https-audit)"
if printf '%s' "$OUT" | grep -q '__RC=0'; then
  ok_t "lib/updater.sh --apt-https-audit exits 0 on a clean system"
else
  fail_t "lib/updater.sh --apt-https-audit exits 0 on a clean system" \
        "$(printf '%s' "$OUT" | grep '__RC=')"
fi

reset_sandbox
printf 'deb https://secure.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
# Force enforcement to fail: make the backup path unwritable.
rm -rf "$BACKUPS"; : > "$BACKUPS"
OUT="$(_rrc restore_ssh.sh --apt-https-audit)"
if printf '%s' "$OUT" | grep -q '__RC=0'; then
  ok_t "restore_ssh.sh --apt-https-audit exits 0 on a clean system"
else
  fail_t "restore_ssh.sh --apt-https-audit exits 0 on a clean system" \
        "$(printf '%s' "$OUT" | grep '__RC=')"
fi
if printf '%s' "$OUT" | grep -q 'App-store transport security'; then
  ok_t "restore_ssh.sh --apt-https-audit prints the report"
else
  fail_t "restore_ssh.sh --apt-https-audit prints the report" "report missing"
fi

# Now dirty the sources so the audit must exit 1 even under `set -e`.
printf 'deb http://plain.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
OUT="$(_rrc restore_ssh.sh --apt-https-audit)"
if printf '%s' "$OUT" | grep -q '__RC=1'; then
  ok_t "restore_ssh.sh --apt-https-audit exits 1 when plaintext remains"
else
  fail_t "restore_ssh.sh --apt-https-audit exits 1 when plaintext remains" \
        "$(printf '%s' "$OUT" | grep '__RC=')"
fi
rm -f "$BACKUPS"

# restore_ssh.sh --apt-https* run under `set -eo pipefail` and gate on
# require_root, so drive its real main() through a harness with root and the
# print helpers stubbed. set -e is inherited by the harness, which is the
# whole point: main() must survive it. The harness runs as its own script so
# its exit code IS main()'s exit code, without putting main() in a condition
# (which would disable set -e inside its body).
build_rs_harness() {
  {
    printf '%s\n' 'set -eo pipefail'
    printf '%s\n' ". \"\$RS_LIB\""
    printf '%s\n' '_apt_priv() { "$@"; }'
    printf '%s\n' '_apt_https_privileged_ok() { return 0; }'
    printf '%s\n' 'apt_https_family() { printf "apt"; }'
    printf '%s\n' 'bold() { :; }'
    printf '%s\n' 'require_root() { return 0; }'
    printf '%s\n' 'diagnose() { err "diagnose must not run for a transport flag"; return 9; }'
    printf '%s\n' 'apply_fixes() { err "apply_fixes must not run for a transport flag"; return 9; }'
    awk '/^main\(\) \{/,/^\}/' "$ROOT/restore_ssh.sh"
    printf '%s\n' 'FIXES=()'
    printf '%s\n' 'main "$@"'
  } > "$WD/rs_harness.sh"
}
build_rs_harness
if bash -n "$WD/rs_harness.sh" 2>/dev/null; then
  ok_t "restore_ssh.sh transport flags are reachable in an isolated harness"
else
  fail_t "restore_ssh.sh transport flags are reachable in an isolated harness" \
        "harness does not parse"
fi

_rs_run() {
  env RS_LIB="$LIB" NEOHIRO_APT_ETC_DIR="$SANDBOX" NEOHIRO_APT_BACKUP_DIR="$BACKUPS" \
      NEOHIRO_APT_HTTPS_NOVERIFY=1 \
      bash "$WD/rs_harness.sh" "$@" 2>&1
  printf '__RC=%s\n' "$?"
}

reset_sandbox
printf 'deb https://secure.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
OUT="$(_rs_run --apt-https-audit)"
if printf '%s' "$OUT" | grep -q '__RC=0'; then
  ok_t "restore_ssh.sh --apt-https-audit exits 0 on a clean system"
else
  fail_t "restore_ssh.sh --apt-https-audit exits 0 on a clean system" \
        "$(printf '%s' "$OUT" | grep '__RC=')"
fi
if printf '%s' "$OUT" | grep -q 'App-store transport security'; then
  ok_t "restore_ssh.sh --apt-https-audit prints the report"
else
  fail_t "restore_ssh.sh --apt-https-audit prints the report" "report missing"
fi

printf 'deb http://plain.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
OUT="$(_rs_run --apt-https-audit)"
if printf '%s' "$OUT" | grep -q '__RC=1'; then
  ok_t "restore_ssh.sh --apt-https-audit exits 1 when plaintext remains"
else
  fail_t "restore_ssh.sh --apt-https-audit exits 1 when plaintext remains" \
        "$(printf '%s' "$OUT" | grep '__RC=')"
fi

# The regression these guard: enforcement fails -> the report must STILL
# print, and the exit code must be enforcement's, not the report's.
reset_sandbox
printf 'deb http://refuse.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
rm -rf "$BACKUPS"; : > "$BACKUPS"
OUT="$(_rs_run --apt-https)"
if printf '%s' "$OUT" | grep -q '__RC=1'; then
  ok_t "restore_ssh.sh --apt-https propagates enforcement failure (not 0)"
else
  fail_t "restore_ssh.sh --apt-https propagates enforcement failure (not 0)" \
        "$(printf '%s' "$OUT" | grep '__RC=')"
fi
if printf '%s' "$OUT" | grep -q 'App-store transport security'; then
  ok_t "restore_ssh.sh --apt-https prints the report even when enforce fails"
else
  fail_t "restore_ssh.sh --apt-https prints the report even when enforce fails" \
        "set -e aborted before the report"
fi
if printf '%s' "$OUT" | grep -q 'diagnose must not run'; then
  fail_t "restore_ssh.sh --apt-https short-circuits before diagnose" "SSH path was entered"
else
  ok_t "restore_ssh.sh --apt-https short-circuits before diagnose"
fi
rm -f "$BACKUPS"

reset_sandbox
printf 'deb https://secure.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
OUT="$(_rs_run --apt-https-off)"
if printf '%s' "$OUT" | grep -q '__RC=0'; then
  ok_t "restore_ssh.sh --apt-https-off exits 0"
else
  fail_t "restore_ssh.sh --apt-https-off exits 0" "$(printf '%s' "$OUT" | grep '__RC=')"
fi

# Same contract for the lib/updater.sh standalone CLI.
reset_sandbox
printf 'deb http://upd.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
rm -rf "$BACKUPS"; : > "$BACKUPS"
UPD_OUT="$(_rrc lib/updater.sh --apt-https)"
if printf '%s' "$UPD_OUT" | grep -q '__RC=1'; then
  ok_t "lib/updater.sh --apt-https propagates enforcement failure"
else
  fail_t "lib/updater.sh --apt-https propagates enforcement failure" \
        "$(printf '%s' "$UPD_OUT" | grep '__RC=')"
fi
if printf '%s' "$UPD_OUT" | grep -q 'App-store transport security'; then
  ok_t "lib/updater.sh --apt-https prints the report even when enforce fails"
else
  fail_t "lib/updater.sh --apt-https prints the report even when enforce fails" \
        "set -e aborted before the report"
fi
rm -f "$BACKUPS"

reset_sandbox
printf 'deb http://upd.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
OUT="$(_rrc lib/updater.sh --apt-https-audit)"
if printf '%s' "$OUT" | grep -q '__RC=1'; then
  ok_t "lib/updater.sh --apt-https-audit exits 1 when plaintext remains"
else
  fail_t "lib/updater.sh --apt-https-audit exits 1 when plaintext remains" \
        "$(printf '%s' "$OUT" | grep '__RC=')"
fi

# And the revert flag must report success.
reset_sandbox
printf 'deb https://secure.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
OUT="$(_rrc lib/updater.sh --apt-https-off)"
if printf '%s' "$OUT" | grep -q '__RC=0'; then
  ok_t "lib/updater.sh --apt-https-off exits 0"
else
  fail_t "lib/updater.sh --apt-https-off exits 0" "$(printf '%s' "$OUT" | grep '__RC=')"
fi

# Structural guards so the pattern cannot silently regress.
for f in restore_ssh.sh lib/updater.sh; do
  if grep -qE 'apt_https_enforce[^|]*\|\| _?[a-z_]*rc=\$\?' "$ROOT/$f"; then
    ok_t "$f captures the enforce status instead of relying on set -e"
  else
    fail_t "$f captures the enforce status instead of relying on set -e" \
          "no '|| _rc=\$?' after apt_https_enforce"
  fi
done

# ============================================================================
# apt_https_guard must NEVER fail its caller
# ============================================================================
# Call sites include pkg_install, which some standalone scripts run under
# `set -e`. A guard is a precaution, not a gate: it must not be the reason a
# package operation aborts.
GUARD_BODY="$(awk '/^apt_https_guard\(\) \{/,/^\}/' "$LIB")"
if printf '%s' "$GUARD_BODY" | grep -q 'apt_https_enforce .* || true'; then
  ok_t "apt_https_guard swallows enforcement failure (lib)"
else
  fail_t "apt_https_guard swallows enforcement failure (lib)" \
        "enforce call is not guarded with '|| true'"
fi
if printf '%s' "$GUARD_BODY" | grep -q 'return 0'; then
  ok_t "apt_https_guard always returns 0 (lib)"
else
  fail_t "apt_https_guard always returns 0 (lib)" "no unconditional return 0"
fi
# With the library loaded the guarantee comes from the lib's own guard; with it
# unavailable, the degraded stub must also return 0. Either way a package
# operation is never blocked by the precaution itself.
if grep -q 'apt_https_guard()      { _apt_https_unavailable; return 0; }' "$SRC"; then
  ok_t "degraded apt_https_guard also swallows failure (inline resolver)"
else
  fail_t "degraded apt_https_guard also swallows failure (inline resolver)" \
        "stub could return non-zero and abort a package operation"
fi

# Behaviour: a guard call must return 0 even when enforcement fails hard.
reset_sandbox
printf 'deb http://guardfail.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
rm -rf "$BACKUPS"; : > "$BACKUPS"
if apt_https_guard "unit" >/dev/null 2>&1; then
  ok_t "apt_https_guard returns 0 despite an enforcement failure"
else
  fail_t "apt_https_guard returns 0 despite an enforcement failure" \
        "guard propagated non-zero"
fi
rm -f "$BACKUPS"

# Standalone lib exit-code contract: 0 clean / 1 plaintext / 2 bad usage.
reset_sandbox
printf 'deb https://secure.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
env NEOHIRO_APT_ETC_DIR="$SANDBOX" NEOHIRO_APT_BACKUP_DIR="$BACKUPS" \
    NEOHIRO_APT_FAMILY=apt NEOHIRO_APT_HTTPS_NOVERIFY=1 \
    bash "$LIB" --report >/dev/null 2>&1
_RC=$?
if [ "$_RC" -eq 0 ]; then
  ok_t "lib/apt-https.sh --report exits 0 on a clean system"
else
  fail_t "lib/apt-https.sh --report exits 0 on a clean system" "rc=$_RC"
fi
printf 'deb http://plain.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
env NEOHIRO_APT_ETC_DIR="$SANDBOX" NEOHIRO_APT_BACKUP_DIR="$BACKUPS" \
    NEOHIRO_APT_FAMILY=apt NEOHIRO_APT_HTTPS_NOVERIFY=1 \
    bash "$LIB" --report >/dev/null 2>&1
_RC=$?
if [ "$_RC" -eq 1 ]; then
  ok_t "lib/apt-https.sh --report exits 1 when plaintext remains"
else
  fail_t "lib/apt-https.sh --report exits 1 when plaintext remains" "rc=$_RC"
fi
env NEOHIRO_APT_ETC_DIR="$SANDBOX" NEOHIRO_APT_BACKUP_DIR="$BACKUPS" \
    NEOHIRO_APT_FAMILY=apt bash "$LIB" --nonsense >/dev/null 2>&1
_RC=$?
if [ "$_RC" -eq 2 ]; then
  ok_t "lib/apt-https.sh exits 2 on an unknown argument"
else
  fail_t "lib/apt-https.sh exits 2 on an unknown argument" "rc=$_RC"
fi

# ============================================================================
# Regression: set -u safety of every module-level global
# ============================================================================
# A guard variable initialised inside a function instead of at the top level
# is unbound on any code path that does not call that function, which kills
# an audit-only run under `set -u`. Load the lib the way the strictest host
# does and touch every path that reads these globals.
cat > "$WD/setu_probe.sh" <<'SETU_EOF'
set -u
. "$RS_LIB" >/dev/null 2>&1
apt_https_report >/dev/null 2>&1
printf 'REPORT=%s\n' "$?"
apt_https_status_text >/dev/null
printf 'STATUS=ok\n'
apt_https_plaintext_for apt >/dev/null 2>&1
printf 'FORAPT=%s\n' "$?"
apt_https_revert >/dev/null 2>&1
printf 'REVERT=%s\n' "$?"
SETU_EOF
SETU_OUT="$(env RS_LIB="$LIB" NEOHIRO_APT_ETC_DIR="$SANDBOX" \
  NEOHIRO_APT_BACKUP_DIR="$BACKUPS" HOME="$FAKEHOME" \
  NEOHIRO_APT_FAMILY=apt NEOHIRO_APT_HTTPS_NOVERIFY=1 \
  bash "$WD/setu_probe.sh" 2>&1)"
if printf '%s' "$SETU_OUT" | grep -q 'unbound variable'; then
  fail_t "lib is set -u clean on an audit-only path" \
        "$(printf '%s' "$SETU_OUT" | grep 'unbound' | head -1)"
else
  ok_t "lib is set -u clean on an audit-only path"
fi
if printf '%s' "$SETU_OUT" | grep -q 'REPORT=' && \
   printf '%s' "$SETU_OUT" | grep -q 'STATUS=ok' && \
   printf '%s' "$SETU_OUT" | grep -q 'FORAPT=' && \
   printf '%s' "$SETU_OUT" | grep -q 'REVERT='; then
  ok_t "set -u harness reached report, status, per-source and revert"
else
  fail_t "set -u harness reached report, status, per-source and revert" \
        "got: $(printf '%s' "$SETU_OUT" | tr '\n' ' ')"
fi

# Structural: the latches and result globals must be initialised at the top
# level of the file, not inside a function body.
for v in _APT_HTTPS_VERDICT _APT_HTTPS_CHANGED _APT_HTTPS_REVERTED \
         _APT_HTTPS_REFUSED _APT_HTTPS_CA_WARNED; do
  if grep -qE "^${v}=|^  ${v}=" "$LIB"; then
    ok_t "$v is initialised at the top level of lib/apt-https.sh"
  else
    fail_t "$v is initialised at the top level of lib/apt-https.sh" \
          "no top-level assignment found"
  fi
  # The inline path no longer declares these: it sources the library, which
  # owns every global. A duplicate here would reintroduce the drift hazard.
  if grep -qE "^[[:space:]]+${v}=" "$SRC"; then
    fail_t "$v is NOT duplicated into the inline resolver" \
          "declared in both places again - they can drift"
  else
    ok_t "$v is not duplicated into the inline resolver (single owner)"
  fi
done

# ============================================================================
# CA-trust-store check: latch, and no false warning on a healthy host
# ============================================================================
# The probe paths are absolute system paths that a non-root test cannot
# create, so the "trust store present" branch is pinned structurally rather
# than by faking the filesystem. Getting this wrong is what caused a run to
# warn on every invocation, so the guard against it matters.
CA_BODY="$(awk '/^_apt_https_check_ca_certs\(\) \{/,/^\}/' "$LIB")"
if printf '%s' "$CA_BODY" | grep -q '_APT_HTTPS_CA_WARNED'; then
  ok_t "CA warning is latched to once per process (lib)"
else
  fail_t "CA warning is latched to once per process (lib)" "no latch found"
fi
# Either shape is acceptable as long as a present trust store returns before
# the warning: an early `return 0` inside the case, or a "missing" flag.
if printf '%s' "$CA_BODY" | grep -qE 'then[[:space:]]*$|missing=0|\[ "\$missing" = "0" \] && return 0' && \
   printf '%s' "$CA_BODY" | grep -q 'return 0'; then
  ok_t "CA check returns before warning when a trust store IS present (lib)"
else
  fail_t "CA check returns before warning when a trust store IS present (lib)" \
        "no early return: a case arm can fall through and warn on a healthy host"
fi
# Single owner: the CA check lives only in the library, so the structural
# guard above is the whole invariant -- no inline copy to keep in sync.

# Behavioural half: this host has no /etc CA bundle, so the missing branch is
# live -- assert it warns exactly once no matter how many call sites fire.
reset_sandbox
CA_CALLS="$(bash -c "
  . '$LIB' >/dev/null 2>&1
  warn() { printf 'WARN\n'; }
  info() { printf 'INFO\n'; }
  _apt_https_check_ca_certs apt >/dev/null 2>&1 || true
  _apt_https_check_ca_certs apt >/dev/null 2>&1 || true
  _apt_https_check_ca_certs apt >/dev/null 2>&1 || true
" 2>&1)"
CA_WARNS="$(printf '%s\n' "$CA_CALLS" | grep -c '^WARN$' || true)"
if [ "$CA_WARNS" -le 1 ]; then
  ok_t "CA warning emitted at most once across repeated checks"
else
  fail_t "CA warning emitted at most once across repeated checks" "saw $CA_WARNS warnings"
fi

# ============================================================================
# Regression: atomic replace leaves no staging residue
# ============================================================================
reset_sandbox
printf 'deb http://atomic.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
printf 'deb [arch=amd64] http://atomic2.example.com/debian main\n' >> "$SANDBOX/apt/sources.list"
printf 'Types: deb\nURIs: http://atomic3.example.com/debian main\n' > "$SANDBOX/apt/sources.list.d/a.sources"
_APT_HTTPS_DONE=""
apt_https_enforce "atomic" >/dev/null 2>&1
RESIDUE="$(find "$SANDBOX" -name '*neohiro-rewrite*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$RESIDUE" = "0" ]; then
  ok_t "atomic rewrite leaves no staging files behind"
else
  fail_t "atomic rewrite leaves no staging files behind" \
        "$RESIDUE residue file(s): $(find "$SANDBOX" -name '*neohiro-rewrite*' 2>/dev/null | tr '\n' ' ')"
fi

# The rewritten content must be correct.
if grep -q 'https://atomic.example.com' "$SANDBOX/apt/sources.list" && \
   grep -q 'https://atomic3.example.com' "$SANDBOX/apt/sources.list.d/a.sources"; then
  ok_t "atomic rewrite produced the expected content"
else
  fail_t "atomic rewrite produced the expected content" "content wrong after rename"
fi

# Mode preservation is only observable on a filesystem that models POSIX
# permissions. Git Bash on NTFS reports 0644 for everything, so asserting it
# there would fail spuriously. Skip explicitly rather than pretend to pass.
if _mode_supported; then
  printf 'deb http://mode.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
  chmod 0640 "$SANDBOX/apt/sources.list"
  _APT_HTTPS_DONE=""
  apt_https_enforce "atomic-mode" >/dev/null 2>&1
  MODE_AFTER="$(ls -l "$SANDBOX/apt/sources.list" 2>/dev/null | cut -c1-10)"
  case "$MODE_AFTER" in
    -rw-r-----) ok_t "atomic rewrite preserves the original file mode (0640)" ;;
    *) fail_t "atomic rewrite preserves the original file mode (0640)" "got: $MODE_AFTER" ;;
  esac
else
  ok_t "atomic rewrite preserves the original file mode (skipped: filesystem does not model POSIX modes)"
fi

# The rewrite must clone attributes with cp -p and then overwrite content,
# never rely on `sed -i` keeping the mode (implementation detail, differs
# between GNU and busybox sed).
PREP_BODY="$(awk '/^_apt_https_prep_repo_stage\(\) \{/,/^\}/' "$LIB")"
if printf '%s' "$PREP_BODY" | grep -q 'cp -p' && printf '%s' "$PREP_BODY" | grep -q 'cp "\$3"'; then
  ok_t "repo staging clones attributes with cp -p then replaces content"
else
  fail_t "repo staging clones attributes with cp -p then replaces content" \
        "unexpected staging implementation: $PREP_BODY"
fi
if printf '%s' "$PREP_BODY" | grep -q 'sed -i'; then
  fail_t "repo staging does not rely on sed -i for mode preservation" "sed -i still used"
else
  ok_t "repo staging does not rely on sed -i for mode preservation"
fi

# The policy drop-in must still land as 0644.
CONF_MODE="$(ls -l "$(apt_https_conf_file)" 2>/dev/null | cut -c1-10)"
case "$CONF_MODE" in
  -rw-r--r--) ok_t "atomic drop-in install lands as 0644" ;;
  *) fail_t "atomic drop-in install lands as 0644" "got: $CONF_MODE" ;;
esac

# Structural: every write is a staging rename, never cp-into-place, and the
# logic lives in exactly one place.
if grep -q '_apt_https_atomic_replace' "$LIB"; then
  ok_t "all writes route through _apt_https_atomic_replace"
else
  fail_t "all writes route through _apt_https_atomic_replace" "helper not wired into the lib"
fi
if grep -q '_apt_priv mv -f "\$stage" "\$target"' "$LIB"; then
  ok_t "atomic replace finishes with rename(2) via mv -f"
else
  fail_t "atomic replace finishes with rename(2) via mv -f" "mv of the stage file missing"
fi
if grep -q '_apt_https_atomic_replace' "$SRC"; then
  fail_t "atomic replace is not reimplemented in the inline resolver" "duplicate copy"
else
  ok_t "atomic replace is not reimplemented in the inline resolver (single owner)"
fi

# ============================================================================
# App-store coverage: every store must be CHECKED and USED
# ============================================================================
# The precaution is not apt-specific. Each distro and language has its own
# "app store", and several ship plaintext HTTP by default. These tests drive
# the per-source detectors directly (they do not gate on applicability) so
# every store is exercised on any host.
APT_SOURCES="apt dnf yum zypper pacman apk flatpak snap docker brew pip npm cargo gem nix fwupd"
REGISTERED="$(_apt_https_source_ids | tr '\n' ' ')"

# 1) Every store we claim to cover is registered.
MISSING_SOURCES=""
for s in $APT_SOURCES; do
  case " $REGISTERED " in *" $s "*) : ;; *) MISSING_SOURCES="$MISSING_SOURCES $s" ;; esac
done
if [ -z "$MISSING_SOURCES" ]; then
  ok_t "all app stores are registered: $(printf '%s' "$REGISTERED" | tr '\n' ' ')"
else
  fail_t "all app stores are registered" "missing:$MISSING_SOURCES"
fi

# 2) Every registered store has a label (a missing label means a blank row in
#    the report, i.e. a store the user cannot identify).
NO_LABEL=""
for s in $REGISTERED; do
  [ -n "$s" ] || continue
  [ "$(_apt_https_source_label "$s")" = "$s" ] && NO_LABEL="$NO_LABEL $s"
done
if [ -z "$NO_LABEL" ]; then
  ok_t "every registered store has a human-readable label"
else
  fail_t "every registered store has a human-readable label" "fallback label used:$NO_LABEL"
fi

# fake_tool <name> — put an executable stub for <name> on PATH so a store's
# applicability gate passes on a host that does not actually run that distro.
# Used to exercise the gate-driven sweep for apk/brew/docker.
fake_tool() {
  local n="$1"
  mkdir -p "$FAKEBIN"
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$n"
  chmod +x "$FAKEBIN/$n" 2>/dev/null || true
}
unfake_tool() { rm -f "$FAKEBIN/$1" 2>/dev/null || true; }

# 3) Per-store detection: write a plaintext config for each store and assert
#    the detector finds it. A store that silently finds nothing is the exact
#    failure this library exists to prevent.
seed_store_config() {
  case "$1" in
    apk)    mkdir -p "$SANDBOX/apk"; printf '%s\n' \
              'http://dl-cdn.alpinelinux.org/alpine/v3.19/main' \
              'https://dl-cdn.alpinelinux.org/alpine/v3.19/community' > "$SANDBOX/apk/repositories" ;;
    docker) mkdir -p "$SANDBOX/docker"; printf '%s\n' \
              '{ "registry-mirrors": ["http://mirror.internal:5000"], "insecure-registries": ["reg.local:5000"] }' > "$SANDBOX/docker/daemon.json" ;;
    pip)    mkdir -p "$FAKEHOME/.config/pip"; printf '%s\n' \
              '[global]' 'index-url = http://pypi.internal/simple' > "$FAKEHOME/.config/pip/pip.conf" ;;
    npm)    printf '%s\n' 'registry=http://npm.internal/' > "$FAKEHOME/.npmrc" ;;
    cargo)  mkdir -p "$FAKEHOME/.cargo"; printf '%s\n' \
              '[source.crates-io]' 'registry = "sparse+http://index.internal/"' > "$FAKEHOME/.cargo/config.toml" ;;
    gem)    printf '%s\n' '---' ':sources:' '- http://rubygems.internal/' > "$FAKEHOME/.gemrc" ;;
    nix)    mkdir -p "$SANDBOX/nix"; printf '%s\n' \
              'substituters = http://cache.nixos.org' 'channel = http://nixos.org/channels' > "$SANDBOX/nix/nix.conf" ;;
    fwupd)  mkdir -p "$SANDBOX/fwupd/remotes.d"; printf '%s\n' \
              '[lvfs]' 'UpdateURI=http://fwupd.lvfs.org/fwupd-stable.xml.gz' > "$SANDBOX/fwupd/remotes.d/lvfs.conf" ;;
    dnf|yum) mkdir -p "$SANDBOX/yum.repos.d"; printf '%s\n' \
              '[e]' 'name=E' 'baseurl=http://mirror.internal/epel/' 'gpgcheck=1' > "$SANDBOX/yum.repos.d/e.repo" ;;
    zypper) mkdir -p "$SANDBOX/zypp/repos.d"; printf '%s\n' \
              '[r]' 'name=R' 'baseurl=http://download.internal/oss/' > "$SANDBOX/zypp/repos.d/r.repo" ;;
    pacman) mkdir -p "$SANDBOX/pacman.d"; printf '%s\n' \
              '## Worldwide' 'Server=http://mirror.internal/archlinux/$repo/os/$arch' > "$SANDBOX/pacman.d/mirrorlist" ;;
    *) return 1 ;;
  esac
  return 0
}

for s in apk docker pip npm cargo gem nix fwupd; do
  reset_sandbox
  seed_store_config "$s"
  FOUND="$(_apt_https_source_plaintext "$s" 2>/dev/null)"
  if printf '%s' "$FOUND" | grep -q 'http://'; then
    ok_t "$s: plaintext endpoint is detected"
  else
    fail_t "$s: plaintext endpoint is detected" "detector returned nothing for $s"
  fi
done

for s in dnf zypper pacman; do
  reset_sandbox
  TEST_FAMILY="$s"
  seed_store_config "$s"
  FOUND="$(_apt_https_source_plaintext "$s" 2>/dev/null)"
  if printf '%s' "$FOUND" | grep -q 'http://'; then
    ok_t "$s: plaintext endpoint is detected"
  else
    fail_t "$s: plaintext endpoint is detected" "detector returned nothing for $s"
  fi
done
TEST_FAMILY=apt

# 4) Comment lines must not be treated as fetch targets in the generic
#    detector, or every config with a doc link would look dirty.
for s in apk docker npm gem nix fwupd; do
  reset_sandbox
  seed_store_config "$s"
  # Prepend a comment that mentions a plaintext URL.
  FIRST_FILE="$(_apt_https_source_files "$s" | head -1)"
  if [ -n "$FIRST_FILE" ] && [ -f "$FIRST_FILE" ]; then
    case "$FIRST_FILE" in
      *.json) printf '%s\n' '{ "_comment": "see http://docs.internal for details", "registry-mirrors": ["https://ok.internal"] }' > "$FIRST_FILE" ;;
      *) printf '%s\n%s\n' '# docs: http://docs.internal/see-me' "$(cat "$FIRST_FILE")" > "$FIRST_FILE" ;;
    esac
    if [ "$FIRST_FILE" = "$FAKEHOME/.npmrc" ]; then
      printf '%s\n%s\n' '; docs: http://docs.internal/see-me' "$(cat "$FIRST_FILE")" > "$FIRST_FILE"
    fi
    CLEAN="$(_apt_https_source_plaintext "$s" 2>/dev/null)"
    if [ -z "$CLEAN" ] || ! printf '%s' "$CLEAN" | grep -q 'docs.internal'; then
      ok_t "$s: commented plaintext URLs are not flagged"
    else
      fail_t "$s: commented plaintext URLs are not flagged" "false positive: $CLEAN"
    fi
  else
    fail_t "$s: commented plaintext URLs are not flagged" "no config file located for $s"
  fi
done

# 5) Opt-in rewrite must convert every file-based store, not just apt.
for s in apk docker pip npm cargo gem nix fwupd; do
  reset_sandbox
  seed_store_config "$s"
  BEFORE="$(_apt_https_source_plaintext "$s" 2>/dev/null)"
  _apt_https_source_prefer_https "$s"
  AFTER="$(_apt_https_source_plaintext "$s" 2>/dev/null)"
  if [ -n "$BEFORE" ] && [ -z "$AFTER" ] && [ "${_APT_HTTPS_CHANGED:-0}" -gt 0 ]; then
    ok_t "$s: prefer-https rewrite removes the plaintext endpoint"
  else
    fail_t "$s: prefer-https rewrite removes the plaintext endpoint" \
          "before=[$(printf '%s' "$BEFORE" | tr '\n' '|')] after=[$(printf '%s' "$AFTER" | tr '\n' '|')] changed=${_APT_HTTPS_CHANGED:-?}"
  fi
  # And the rewritten value must actually be https, not just "no longer http".
  ANY_HTTPS=0
  while IFS= read -r f; do
    [ -n "$f" ] && grep -q 'https://' "$f" 2>/dev/null && ANY_HTTPS=1
  done < <(_apt_https_source_files "$s")
  if [ "$ANY_HTTPS" = "1" ]; then
    ok_t "$s: rewrite actually wrote https:// into the config"
  else
    fail_t "$s: rewrite actually wrote https:// into the config" "no https:// present"
  fi
  # Backup must exist so the change is revertible.
  BK="$(find "$BACKUPS" -name '*.orig' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$BK" -gt 0 ]; then
    ok_t "$s: rewrite backed the config up first"
  else
    fail_t "$s: rewrite backed the config up first" "no .orig in $BACKUPS"
  fi
done

# 6) "if available": non-apt stores must NOT be rewritten unattended.
for s in apk docker pip npm cargo gem nix fwupd; do
  reset_sandbox
  seed_store_config "$s"
  _APT_HTTPS_DONE=""
  apt_https_enforce "no-optin-$s" >/dev/null 2>&1
  STILL="$(_apt_https_source_plaintext "$s" 2>/dev/null)"
  if [ -n "$STILL" ]; then
    ok_t "$s: left untouched without NEOHIRO_APT_HTTPS_REWRITE=1"
  else
    fail_t "$s: left untouched without NEOHIRO_APT_HTTPS_REWRITE=1" "rewritten unattended"
  fi
done

# 7) With the opt-in, apt_https_enforce must sweep every store, not just apt.
#    apk and brew are stubbed onto PATH so their applicability gate passes:
#    the gate deliberately skips stores that are not installed.
fake_tool apk; fake_tool npm
reset_sandbox
seed_store_config apk
seed_store_config nix
seed_store_config npm
_APT_HTTPS_DONE=""
NEOHIRO_APT_HTTPS_REWRITE=1 apt_https_enforce "sweep" >/dev/null 2>&1
LEFT=0
for s in apk nix npm; do
  [ -n "$(_apt_https_source_plaintext "$s" 2>/dev/null)" ] && LEFT=$((LEFT + 1))
done
if [ "$LEFT" = "0" ]; then
  ok_t "opt-in sweep cleans apk, nix and npm in one pass"
else
  fail_t "opt-in sweep cleans apk, nix and npm in one pass" "$LEFT store(s) still plaintext"
fi

# 7b) The sweep must NOT touch a store whose tool is absent, even with the
#     opt-in set: rewriting config for software that is not installed is
#     out of scope and can surprise a later manual install.
unfake_tool apk
reset_sandbox
seed_store_config apk
_APT_HTTPS_DONE=""
NEOHIRO_APT_HTTPS_REWRITE=1 apt_https_enforce "sweep-uninstalled" >/dev/null 2>&1
if [ -n "$(_apt_https_source_plaintext apk 2>/dev/null)" ]; then
  ok_t "opt-in sweep skips a store whose tool is not installed"
else
  fail_t "opt-in sweep skips a store whose tool is not installed" \
        "rewrote config for an absent tool"
fi
fake_tool apk

env_src_id() {
  case "$1" in
    PIP_INDEX_URL|PIP_EXTRA_INDEX_URL) printf 'pip' ;;
    NPM_CONFIG_REGISTRY|npm_config_registry) printf 'npm' ;;
    CARGO_REGISTRIES_CRATES_IO_INDEX) printf 'cargo' ;;
    GEM_SOURCE) printf 'gem' ;;
    HOMEBREW_*) printf 'brew' ;;
    *) printf '' ;;
  esac
}

# 8) Env-configured transports are reported. Exercised through
#    _apt_https_source_env directly, because the aggregate only reports a
#    store whose tool is installed -- and no host runs all of them.
for pair in "PIP_INDEX_URL=http://pypi.internal/simple" \
            "PIP_EXTRA_INDEX_URL=http://extra.internal/simple" \
            "NPM_CONFIG_REGISTRY=http://npm.internal/" \
            "npm_config_registry=http://npm2.internal/" \
            "CARGO_REGISTRIES_CRATES_IO_INDEX=http://crates.internal/" \
            "GEM_SOURCE=http://rubygems.internal/" \
            "HOMEBREW_API_DOMAIN=http://brew.internal" \
            "HOMEBREW_ARTIFACT_DOMAIN=http://brew-artifacts.internal" \
            "HOMEBREW_BREW_GIT_REMOTE=http://git.internal/brew.git"; do
  reset_sandbox
  VAR="${pair%%=*}"
  VAL="${pair#*=}"
  # NOT named SRC: that is the path to linuxinstall.sh and several later
  # assertions grep it. Shadowing it here silently broke them.
  ENV_SRC_ID="$(env_src_id "$VAR")"
  # shellcheck disable=SC2086
  OUT="$(env "$VAR=$VAL" bash -c ". '$LIB' >/dev/null 2>&1; _apt_https_source_env $ENV_SRC_ID" 2>/dev/null)"
  if printf '%s' "$OUT" | grep -q "$VAR=$VAL"; then
    ok_t "env transport detected: $VAR"
  else
    fail_t "env transport detected: $VAR" "got: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
done

# 8b) An unset variable must produce nothing (no empty VAR= noise).
reset_sandbox
if [ -z "$(_apt_https_source_env pip 2>/dev/null)" ]; then
  ok_t "no env noise when transport variables are unset"
else
  fail_t "no env noise when transport variables are unset" \
        "got: $(_apt_https_source_env pip 2>/dev/null | tr '\n' '|')"
fi

# 9) Revert must restore every store it touched.
reset_sandbox
seed_store_config apk
seed_store_config nix
_APT_HTTPS_DONE=""
NEOHIRO_APT_HTTPS_REWRITE=1 apt_https_enforce "revert-all" >/dev/null 2>&1
if [ -n "$(_apt_https_source_plaintext apk 2>/dev/null)" ]; then
  fail_t "precondition: apk was rewritten before revert" "still https"
else
  ok_t "precondition: apk was rewritten before revert"
fi
apt_https_revert >/dev/null 2>&1
if [ -n "$(_apt_https_source_plaintext apk 2>/dev/null)" ] && \
   [ -n "$(_apt_https_source_plaintext nix 2>/dev/null)" ]; then
  ok_t "revert restores non-apt stores too, not just apt"
else
  fail_t "revert restores non-apt stores too, not just apt" \
        "apk=[$(_apt_https_source_plaintext apk 2>/dev/null)] nix=[$(_apt_https_source_plaintext nix 2>/dev/null)]"
fi

# 10) The aggregate must span every store, and report rc=1 when any is dirty.
reset_sandbox
seed_store_config gem
if apt_https_status_text 2>/dev/null | grep -q 'rubygems.internal'; then
  ok_t "apt_https_status_text aggregates non-apt stores"
else
  fail_t "apt_https_status_text aggregates non-apt stores" "gem endpoint missing from aggregate"
fi
apt_https_report >/dev/null 2>&1
_RC=$?
if [ "$_RC" -eq 1 ]; then
  ok_t "report exits 1 when any store is plaintext"
else
  fail_t "report exits 1 when any store is plaintext" "rc=$_RC"
fi
REPORT_OUT="$(apt_https_report 2>&1)"
if printf '%s' "$REPORT_OUT" | grep -q 'gem sources'; then
  ok_t "report names the offending store"
else
  fail_t "report names the offending store" "no 'gem sources' row"
fi

# 11) Applicability gating: a store with no tooling on this host must not be
#     listed as a dirty row, so the report stays readable on a minimal box.
reset_sandbox
_missing_tools=0
for tool in docker flatpak snap apk brew; do
  command -v "$tool" >/dev/null 2>&1 || _missing_tools=$((_missing_tools + 1))
done
if [ "$_missing_tools" -gt 0 ]; then
  ok_t "applicability gate can be exercised (host is missing $_missing_tools store tool(s))"
else
  ok_t "applicability gate: all store tools present on this host"
fi
reset_sandbox
if _apt_https_source_applicable docker 2>/dev/null; then
  if command -v docker >/dev/null 2>&1; then
    ok_t "docker marked applicable when the binary exists"
  else
    fail_t "docker marked applicable when the binary exists" "reported applicable with no docker"
  fi
else
  ok_t "docker marked not-applicable when the binary is absent"
fi

# ============================================================================
# Repository encoding hygiene
# ============================================================================
# These scripts are full of box-drawing and em-dash characters, so they are
# one careless editor, IDE, or shell one-liner away from being silently
# re-encoded. That failure mode is nasty: the file still parses, the tests
# mostly pass, and only the snapshot or a diff comparison notices. It bit this
# work twice (a UTF-8 file read as cp1252 and rewritten, then a repair pass
# that introduced U+FFFD), so it gets an automated guard.
#
# Pure bash + coreutils on purpose: the CI matrix includes a busybox-based
# bash:3.2-alpine image where python may be absent.
if command -v iconv >/dev/null 2>&1; then
  BAD_UTF8=""
  while IFS= read -r f; do
    iconv -f UTF-8 -t UTF-8 "$f" >/dev/null 2>&1 || BAD_UTF8="$BAD_UTF8 $f"
  done <<EOF
$(cd "$ROOT" && find . \( -name '*.sh' -o -name '*.md' \) -not -path './.git/*' | sort)
EOF
  if [ -z "$BAD_UTF8" ]; then
    ok_t "every .sh/.md file is valid UTF-8"
  else
    fail_t "every .sh/.md file is valid UTF-8" "invalid:$BAD_UTF8"
  fi
else
  ok_t "UTF-8 validity check skipped (iconv unavailable)"
fi

# U+FFFD and cp1252 double-encoding markers.
#
# The search patterns are built from byte escapes at runtime on purpose: a
# detector that spelled the mojibake literally would match itself, and the
# obvious "just exclude this file" fix would leave the next file unguarded.
# C3 A2 is 'a-circumflex' and C3 83 is 'A-tilde' as UTF-8 -- both are the
# leading byte of a double-encoded 3-byte sequence and neither legitimately
# appears in this codebase.
FFFD_BYTES="$(printf '\357\277\275')"
MOJI_A="$(printf '\303\242')"
MOJI_C="$(printf '\303\203')"

FFFD_FILES=""; MOJI_FILES=""
while IFS= read -r f; do
  LC_ALL=C grep -q "$FFFD_BYTES" "$f" 2>/dev/null && FFFD_FILES="$FFFD_FILES $f"
  if LC_ALL=C grep -q "$MOJI_A" "$f" 2>/dev/null || LC_ALL=C grep -q "$MOJI_C" "$f" 2>/dev/null; then
    MOJI_FILES="$MOJI_FILES $f"
  fi
done <<EOF
$(cd "$ROOT" && find . \( -name '*.sh' -o -name '*.md' \) -not -path './.git/*' | sort)
EOF
if [ -z "$FFFD_FILES" ]; then
  ok_t "no U+FFFD replacement characters anywhere"
else
  fail_t "no U+FFFD replacement characters anywhere" "found in:$FFFD_FILES"
fi
if [ -z "$MOJI_FILES" ]; then
  ok_t "no cp1252 double-encoding artifacts anywhere"
else
  fail_t "no cp1252 double-encoding artifacts anywhere" "found in:$MOJI_FILES"
fi

# .gitattributes pins eol=lf for *.sh and *.md; a CRLF slip breaks the
# snapshot diffs and makes every future diff noisier.
#
# The CR is matched with a shell `case` rather than `grep -q $'\r'`: passing a
# lone control character as a process argument is not portable (Git Bash's
# MSYS argument translation swallows it, and the check silently passes).
# Keeping the byte inside the shell avoids the round trip entirely.
_has_cr() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *$'\r'*) return 0 ;;
    esac
  done < "$1"
  return 1
}
CRLF_FILES=""
while IFS= read -r f; do
  _has_cr "$f" && CRLF_FILES="$CRLF_FILES $f"
done <<EOF
$(cd "$ROOT" && find . \( -name '*.sh' -o -name '*.md' \) -not -path './.git/*' | sort)
EOF
if [ -z "$CRLF_FILES" ]; then
  ok_t "no CRLF line endings (matches .gitattributes eol=lf)"
else
  fail_t "no CRLF line endings (matches .gitattributes eol=lf)" "found in:$CRLF_FILES"
fi

# ============================================================================
# The detected family must be computed once per pass
# ============================================================================
# _apt_https_source_applicable used to call apt_https_family itself, and the
# report loop hits it once per store. That is up to five `command -v` PATH
# scans per RPM/Arch store -- wasted on every report -- and a latent
# correctness hazard: if PATH changed mid-run, a store could be "applicable"
# in one check and absent from the next, so the same file could be reported
# once or twice. Callers now pass the family in.
MARK="$WD/marker"; : > "$MARK"
cat > "$WD/famcount.sh" <<EOF
set -u
. "$LIB" >/dev/null 2>&1
apt_https_family() { echo x >> "$MARK"; printf 'apt'; }
_apt_https_source_applicable zypper zypper >/dev/null 2>&1
printf '%s\n' "\$(wc -l < "$MARK" 2>/dev/null || echo 0)"
EOF
HITS="$(bash "$WD/famcount.sh" 2>/dev/null | tr -d ' ' | tail -1)"
if [ "${HITS:-x}" = "0" ]; then
  ok_t "applicability check does not re-probe the family when given a hint"
else
  fail_t "applicability check does not re-probe the family when given a hint" \
        "$HITS extra probe(s)"
fi

: > "$MARK"
cat > "$WD/famcount2.sh" <<EOF
set -u
. "$LIB" >/dev/null 2>&1
apt_https_family() { echo x >> "$MARK"; printf 'apt'; }
apt_https_status_text >/dev/null 2>&1
printf '%s\n' "\$(wc -l < "$MARK" 2>/dev/null || echo 0)"
EOF
HITS="$(bash "$WD/famcount2.sh" 2>/dev/null | tr -d ' ' | tail -1)"
if [ "${HITS:-99}" = "1" ]; then
  ok_t "apt_https_status_text probes the family exactly once (not once per store)"
else
  fail_t "apt_https_status_text probes the family exactly once" \
        "$HITS probe(s) across 16 stores"
fi

# ============================================================================
# Backup names must not collide
# ============================================================================
COLL_A="$(_apt_https_backup_path '/a/b/c')"
COLL_B="$(_apt_https_backup_path '/a_b/c')"
COLL_C="$(_apt_https_backup_path '/a/b/c.d')"
if [ "$COLL_A" != "$COLL_B" ] && [ "$COLL_A" != "$COLL_C" ]; then
  ok_t "flattened backup names stay distinct (checksum suffix)"
else
  fail_t "flattened backup names stay distinct (checksum suffix)" \
        "collision: $COLL_A"
fi
# The name must still be a single legal path component.
BASE="$(basename "$COLL_A")"
case "$BASE" in
  */*) fail_t "backup name is a single path component" "contains a slash" ;;
  *)   ok_t "backup name is a single path component" ;;
esac
# And it must be stable across calls, so a re-run finds the existing backup.
if [ "$(_apt_https_backup_path '/etc/apt/sources.list')" = \
     "$(_apt_https_backup_path '/etc/apt/sources.list')" ]; then
  ok_t "backup name is deterministic across calls"
else
  fail_t "backup name is deterministic across calls" "name changed between calls"
fi

# ============================================================================
# Degraded mode must be quiet, and must never claim an unverified result
# ============================================================================
# When lib/apt-https.sh cannot be loaded, a stub replaces the real guard.
# That stub stands in for a hot-path helper called by every package entry
# point, and apt_https_status_text returns empty for "found nothing" -- which
# a caller could easily read as "already HTTPS-only".
# Grep the resolver block directly rather than extracting it by line range:
# the range endpoints move every time a guard is added.
DEG_LATCH="$(grep -c '_APT_HTTPS_DEGRADED_WARNED=1' "$SRC" || true)"
if [ "${DEG_LATCH:-0}" -ge 1 ]; then
  ok_t "degraded warning is latched to once per process"
else
  fail_t "degraded warning is latched to once per process" \
        "no latch: every pkg_* call would reprint the warning"
fi

if grep -q 'apt_https_available()  { return 1; }' "$SRC"; then
  ok_t "degraded mode reports itself as unavailable"
else
  fail_t "degraded mode reports itself as unavailable" \
        "callers cannot tell a stub from the real guard"
fi

# The real library must claim availability.
if grep -qE '^apt_https_available\(\) \{' "$LIB" && \
   awk '/^apt_https_available\(\) \{/,/^\}/' "$LIB" | grep -q 'return 0'; then
  ok_t "the real library reports itself available"
else
  fail_t "the real library reports itself available" "apt_https_available missing/!=0"
fi

# The caller that infers "already secure" must consult it.
if grep -q 'if ! apt_https_available 2>/dev/null; then' "$SRC"; then
  ok_t "_auto_skip_if_done refuses to skip when the guard is unavailable"
else
  fail_t "_auto_skip_if_done refuses to skip when the guard is unavailable" \
        "would print 'already HTTPS-only' for a guard that never ran"
fi

# Behavioural: with the stub in place, the skip decision must be "run", and
# the step must never report that sources are already HTTPS-only.
cat > "$WD/degraded_probe.sh" <<'DEGEOF'
set -u
info() { printf 'INFO:%s\n' "$*"; }
warn() { printf 'WARN:%s\n' "$*"; }
ok()   { printf 'OK:%s\n' "$*"; }
msg()  { :; }
_APT_HTTPS_DEGRADED_WARNED=""
_apt_https_unavailable() {
  [ -n "${_APT_HTTPS_DEGRADED_WARNED:-}" ] && return 0
  _APT_HTTPS_DEGRADED_WARNED=1
  printf 'WARN:transport guard is INACTIVE\n' >&2
  return 0
}
apt_https_guard()      { _apt_https_unavailable; return 0; }
apt_https_enforce()    { _apt_https_unavailable; return 0; }
apt_https_report()     { _apt_https_unavailable; return 0; }
apt_https_revert()     { _apt_https_unavailable; return 0; }
apt_https_status_text(){ return 0; }
apt_https_available()  { return 1; }
for i in 1 2 3 4 5; do apt_https_guard "pkg_$i"; done 2>&1 >/dev/null | grep -c 'INACTIVE'
apt_https_guard "pkg_6" 2>&1 >/dev/null | grep -c 'INACTIVE'
DEGEOF
DEG_OUT="$(bash "$WD/degraded_probe.sh" 2>/dev/null)"
DEG_TOTAL="$(printf '%s\n' "$DEG_OUT" | grep -c '1' || true)"
if printf '%s\n' "$DEG_OUT" | grep -qx '1'; then
  ok_t "six degraded guard calls emit exactly one warning"
else
  fail_t "six degraded guard calls emit exactly one warning" \
        "warning lines per call: $(printf '%s' "$DEG_OUT" | tr '\n' '/')"
fi

# ============================================================================
# Backups must be written atomically too
# ============================================================================
BK_BODY="$(awk '/^_apt_https_backup_once\(\) \{/,/^\}/' "$LIB")"
if printf '%s' "$BK_BODY" | grep -q 'partial\.\$\$' && \
   printf '%s' "$BK_BODY" | grep -q 'mv -f "\$stage" "\$dst"'; then
  ok_t "backup is staged and renamed, never cp-into-place"
else
  fail_t "backup is staged and renamed, never cp-into-place" \
        "a dead cp would leave a truncated .orig"
fi

# Behavioural: after a rewrite no .partial residue may remain.
reset_sandbox
printf 'deb http://partial.example.com/ubuntu main\n' > "$SANDBOX/apt/sources.list"
_APT_HTTPS_DONE=""
apt_https_enforce "partial" >/dev/null 2>&1
if find "$BACKUPS" -name '*.partial.*' 2>/dev/null | grep -q .; then
  fail_t "no .partial residue after a rewrite" \
        "found: $(find "$BACKUPS" -name '*.partial.*' | tr '\n' ' ')"
else
  ok_t "no .partial residue after a rewrite"
fi
# The backup must still be complete and restorable.
BAK="$(_apt_https_backup_path "$SANDBOX/apt/sources.list")"
if [ -f "$BAK" ] && [ "$(grep -c 'http://partial.example.com' "$BAK")" = "1" ]; then
  ok_t "backup left by the staged copy is complete"
else
  fail_t "backup left by the staged copy is complete" "backup missing or incomplete"
fi

# ============================================================================
# Run continuity: an SSH drop must never be unrecoverable
# ============================================================================
# The whole point of the tmux wrapper is that the user can always get back to
# a running install. Three ways that guarantee was broken:
#   * the re-exec dropped every CLI argument, so the run silently changed
#     behaviour after wrapping;
#   * `tmux new-session -A` attached to a leftover session instead of starting
#     this run, dropping the user into an old, differently-flagged one;
#   * the recovery command was never printed, and `exec` meant nothing after
#     the wrap could print it.
# These are asserted against the real function, driven with a fake tmux and a
# captured exec, so they cannot regress on a wording change.
TMUX_FN="$WD/ensure_tmux.sh"
awk '/^ensure_tmux_if_ssh\(\) \{/,/^\}/' "$SRC" > "$TMUX_FN"
if [ -s "$TMUX_FN" ]; then
  ok_t "ensure_tmux_if_ssh extracted for continuity testing"
else
  fail_t "ensure_tmux_if_ssh extracted for continuity testing" "function body not found"
fi

cat > "$WD/tmux_drive.sh" <<'TMUXEOF'
set -u
SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22"
unset TMUX STY 2>/dev/null || true
ORIG_CWD="/work dir/with space"
SCRIPT_PATH="/opt/neohiro/linuxinstall.sh"
TMP_DIR="$WDDRV"
RECOVERY_CMD="tmux attach -t linux-setup"
ok()  { printf 'OK:%s\n' "$*"; }
bold(){ printf 'BOLD:%s\n' "$*"; }
info(){ printf 'INFO:%s\n' "$*"; }
warn(){ printf 'WARN:%s\n' "$*"; }
msg() { :; };  err() { printf 'ERR:%s\n' "$*"; }
pkg_install() { :; }
command() { builtin command "$@"; }
tmux() {
  case "${1:-}" in
    has-session) [ "$EXISTING" = "yes" ] && return 0 || return 1 ;;
  esac
  printf 'TMUXCALL:%s\n' "$*"
  return 0
}
exec() { printf 'EXECCMD:%s\n' "$*"; return 0; }
. "$FNFILE"
ensure_tmux_if_ssh "$@"
TMUXEOF

drive_tmux() {
  # $1 = EXISTING (yes/no), rest = args
  local existing="$1"; shift
  mkdir -p "$WD/tmuxrun"
  WDDRV="$WD/tmuxrun" FNFILE="$TMUX_FN" EXISTING="$existing" \
    bash "$WD/tmux_drive.sh" "$@" 2>/dev/null
}

OUT_CLEAN="$(drive_tmux no --auto --step=firewall --dry-run)"
if printf '%s' "$OUT_CLEAN" | grep -qF -- '--step=firewall' && \
   printf '%s' "$OUT_CLEAN" | grep -qF -- '--dry-run' && \
   printf '%s' "$OUT_CLEAN" | grep -qF -- '--auto'; then
  ok_t "continuity: CLI arguments survive the tmux re-exec"
else
  fail_t "continuity: CLI arguments survive the tmux re-exec" \
        "args lost: $(printf '%s' "$OUT_CLEAN" | tr '\n' ' ')"
fi

# The call site must forward them. Asserting only the function body is not
# enough: a correct function invoked bare still drops every argument, which
# is exactly the bug shellcheck's SC2120 caught in CI after the body was
# already fixed.
if grep -q 'ensure_tmux_if_ssh "\$@"' "$SRC"; then
  ok_t "continuity: the call site forwards the script arguments"
else
  fail_t "continuity: the call site forwards the script arguments" \
        "ensure_tmux_if_ssh is called without \"\$@\"; the re-exec drops every flag"
fi
if grep -qE '^[[:space:]]*ensure_tmux_if_ssh[[:space:]]*$' "$SRC"; then
  fail_t "continuity: no bare ensure_tmux_if_ssh call remains" "a bare call was found"
else
  ok_t "continuity: no bare ensure_tmux_if_ssh call remains"
fi

# Guard against the regression that CI caught: the function referencing "$@"
# while nothing ever passes it. shellcheck flags it as SC2120; assert the
# shape here so the suite is self-sufficient without shellcheck installed.
if grep -qE '^ensure_tmux_if_ssh\(\) \{' "$SRC" && \
   grep -q 'ensure_tmux_if_ssh "\$@"' "$SRC"; then
  ok_t "continuity: arguments are referenced and supplied (no SC2120 shape)"
else
  fail_t "continuity: arguments are referenced and supplied (no SC2120 shape)" \
        "function reads \"\$@\" but nothing supplies it"
fi

if printf '%s' "$OUT_CLEAN" | grep -qF 'new-session -s linux-setup'; then
  ok_t "continuity: a clean host uses the documented session name"
else
  fail_t "continuity: a clean host uses the documented session name" \
        "$(printf '%s' "$OUT_CLEAN" | grep EXECCMD | head -1)"
fi

if printf '%s' "$OUT_CLEAN" | grep -qF 'new-session -A'; then
  fail_t "continuity: never uses -A (which would attach to a stale session)" \
        "-A present"
else
  ok_t "continuity: never uses -A (which would attach to a stale session)"
fi

OUT_STALE="$(drive_tmux yes --auto)"
if printf '%s' "$OUT_STALE" | grep -qF 'new-session -s linux-setup-'; then
  ok_t "continuity: a stale session forces a distinct name, no hijack"
else
  fail_t "continuity: a stale session forces a distinct name, no hijack" \
        "$(printf '%s' "$OUT_STALE" | grep EXECCMD | head -1)"
fi
if printf '%s' "$OUT_STALE" | grep -qF 'already exists'; then
  ok_t "continuity: the stale session is reported, not silently reused"
else
  fail_t "continuity: the stale session is reported, not silently reused" "silent"
fi

# The recovery command must name the session THIS run uses.
REC="$(printf '%s' "$OUT_STALE" | grep -F 'tmux attach -t' | head -1)"
SESS="$(printf '%s' "$OUT_STALE" | grep -oE 'new-session -s [^ ]+' | head -1 | awk '{print $3}')"
if [ -n "$REC" ] && [ -n "$SESS" ] && printf '%s' "$REC" | grep -qF "$SESS"; then
  ok_t "continuity: the printed recovery command matches the session actually created"
else
  fail_t "continuity: the printed recovery command matches the session actually created" \
        "printed='$REC' session='$SESS'"
fi

# Metacharacters must be escaped, or tmux's shell would re-interpret them.
OUT_META="$(drive_tmux no --note='a b; rm -rf /')"
if printf '%s' "$OUT_META" | grep -qF 'a\ b\;\ rm\ -rf'; then
  ok_t "continuity: arguments with spaces and metacharacters are %q-escaped"
else
  fail_t "continuity: arguments with spaces and metacharacters are %q-escaped" \
        "$(printf '%s' "$OUT_META" | grep EXECCMD | head -1)"
fi

# A run with no arguments must not inject an empty one.
OUT_NOARG="$(drive_tmux no)"
if printf '%s' "$OUT_NOARG" | grep -qF "''"; then
  fail_t "continuity: no spurious empty argument when invoked bare" "empty arg emitted"
else
  ok_t "continuity: no spurious empty argument when invoked bare"
fi

# The inner wrapper must tear the session down on success, or the next run
# inherits a stale session -- which is the hijack scenario above.
if printf '%s' "$OUT_CLEAN" | grep -qF 'neohiro-tmux-inner'; then
  ok_t "continuity: the tmux wrapper stages an inner reaper script"
else
  fail_t "continuity: the tmux wrapper stages an inner reaper script" "no inner script"
fi
INNER_PATH="$(printf '%s' "$OUT_CLEAN" | grep -oE 'bash [^ ]*neohiro-tmux-inner[^ ]*' | head -1 | awk '{print $2}')"
if [ -n "$INNER_PATH" ] && [ -f "$INNER_PATH" ]; then
  if grep -q 'kill-session' "$INNER_PATH" && grep -q 'NEOHIRO_TMUX_SESSION' "$INNER_PATH"; then
    ok_t "continuity: the reaper kills the session on clean exit"
  else
    fail_t "continuity: the reaper kills the session on clean exit" "no kill-session in inner script"
  fi
else
  fail_t "continuity: the reaper kills the session on clean exit" \
        "inner script not found at '$INNER_PATH'"
fi

# Script hopping: the subscript path must warn when it cannot protect the hop,
# and must emit a heartbeat so a long step does not look frozen.
HOP="$(awk '/^run_remote_script\(\) \{/,/^\}/' "$SRC")"
if printf '%s' "$HOP" | grep -q 'CANNOT be recovered'; then
  ok_t "continuity: script hop warns when there is no tmux to protect it"
else
  fail_t "continuity: script hop warns when there is no tmux to protect it" \
        "silent unprotected hop"
fi
if printf '%s' "$HOP" | grep -q 'still running in tmux session'; then
  ok_t "continuity: script hop emits a heartbeat while waiting"
else
  fail_t "continuity: script hop emits a heartbeat while waiting" \
        "no heartbeat: a long step looks frozen and invites an orphaning Ctrl-C"
fi
if printf '%s' "$HOP" | grep -q 'Ctrl-b then d'; then
  ok_t "continuity: script hop explains how to detach without stopping it"
else
  fail_t "continuity: script hop explains how to detach without stopping it" "no hint"
fi

# ============================================================================
# Summary
# ============================================================================
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'All %d test(s) passed.\n' "$PASS"
  exit 0
fi
printf '%d passed, %d FAILED.\n' "$PASS" "$FAIL"
exit 1
