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
FAKEBIN="$WD/bin"
mkdir -p "$FAKEBIN"

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
  _APT_HTTPS_DONE=""
  DRY_RUN=0
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

if grep -q 'NEOHIRO_APT_FAMILY' "$SRC" && grep -q 'NEOHIRO_APT_FAMILY' "$LIB"; then
  ok_t "NEOHIRO_APT_FAMILY is honoured by the inline fallback too"
else
  fail_t "NEOHIRO_APT_FAMILY is honoured by the inline fallback too" "missing in one of the two copies"
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

BAK_REL="$(printf '%s' "$SANDBOX" | tr '/' '_')"
BAK_REL="${BAK_REL#/}"
BAK="$BACKUPS/${BAK_REL}_apt_sources.list.orig"
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
if printf '%s' "$DNFOUT" | grep -q 'Plaintext repository URLs remain'; then
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

# lib/updater.sh must guard the dispatcher and every sub-step.
UP="$ROOT/lib/updater.sh"
for fn in _update_apt _update_dnf _update_yum _update_zypper _update_pacman \
          _update_snap _update_flatpak _update_brew _run_all_updates; do
  if grep -q "apt_https_guard \"$fn\"" "$UP"; then
    ok_t "integration: updater $fn() calls apt_https_guard"
  else
    fail_t "integration: updater $fn() calls apt_https_guard" "no guard call"
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
# Parity: linuxinstall.sh's inline fallback must expose the same API
# ============================================================================
INLINE_FNS="apt_https_guard apt_https_enforce apt_https_report apt_https_revert \
apt_https_family apt_https_status_text apt_https_etc_dir apt_https_backup_dir apt_https_conf_file \
_apt_https_repo_files _apt_https_foreign_repo_files _apt_https_plaintext_in_apt_file \
_apt_https_plaintext_in_repo_file _apt_https_backup_path _apt_https_backup_once _apt_https_stage \
_apt_https_write_conf _apt_https_rewrite_file _apt_https_rewrite_apt_sources \
_apt_https_revert_apt_sources _apt_https_audit_family _apt_https_rewrite_family \
_apt_https_flatpak_plaintext _apt_https_check_ca_certs _apt_https_block_port80 _apt_priv \
_apt_https_verify_apt_sources"
MISSING=""
for fn in $INLINE_FNS; do
  grep -qE "^[[:space:]]+${fn}\(\)" "$SRC" || MISSING="$MISSING inline:$fn"
  grep -qE "^${fn}\(\)"       "$LIB" || MISSING="$MISSING lib:$fn"
done
if [ -z "$MISSING" ]; then
  ok_t "inline fallback and lib/apt-https.sh expose the same API"
else
  fail_t "inline fallback and lib/apt-https.sh expose the same API" "missing:$MISSING"
fi

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
# Summary
# ============================================================================
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'All %d test(s) passed.\n' "$PASS"
  exit 0
fi
printf '%d passed, %d FAILED.\n' "$PASS" "$FAIL"
exit 1