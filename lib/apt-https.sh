#!/usr/bin/env bash
# lib/apt-https.sh - HTTPS-only repository enforcement (precautionary guard).
#
# Purpose: BEFORE any package manager in this repo downloads, updates, or
# upgrades anything, make sure repository traffic is authenticated/TLS
# instead of plaintext HTTP.  An on-path attacker who can rewrite an
# http:// mirror URL can otherwise inject arbitrary .deb/.rpm/.pkgz files
# into an otherwise fully-hardened machine.
#
# What "enforce" means per family:
#
#   apt     (Debian / Ubuntu / Mint / Pop!_OS / Kali / derivatives)
#     1. Install a managed policy drop-in
#        /etc/apt/apt.conf.d/99neohiro-force-https:
#          - Acquire::https::AllowRedirect "true"   -> https mirrors that
#              redirect within https are allowed.
#          - Acquire::http::AllowRedirect  "false"  -> a redirect from
#              https:// down to http:// is REFUSED instead of silently
#              followed.  This is the anti-downgrade control.
#          - Acquire::https::Verify-Peer/Verify-Host "true"
#          - Acquire::Retries "3"
#     2. Rewrite http:// -> https:// in every repo definition:
#          /etc/apt/sources.list
#          /etc/apt/sources.list.d/*.list   (classic one-line format)
#          /etc/apt/sources.list.d/*.sources (DEB822: URIs: field only)
#        Comments are left untouched.  Every touched file is backed up to
#        /var/backups/neohiro-apt-https/ before the first edit.
#     3. Verify with a real `apt-get update`.  If the rewrite broke the
#        mirrors, the backups are restored automatically so the machine is
#        never left with an unusable package manager.
#
#   dnf / yum / zypper / pacman / flatpak
#     No blind rewrite.  Many upstream mirrors do not serve the same paths
#     over TLS, and silently breaking a working repo is worse than the
#     threat.  Instead: audit, report every plaintext entry, and offer an
#     opt-in rewrite via NEOHIRO_APT_HTTPS_REWRITE=1.
#
# Optional hardening (NOT default, because a global outbound port-80 block
# also breaks legitimate plaintext tooling such as local registries and
# metrics endpoints):
#   NEOHIRO_APT_BLOCK_PORT80=1  ->  ufw deny out 80/tcp
#
# Full environment surface:
#   NEOHIRO_APT_HTTPS=1        enforce (default)
#   NEOHIRO_APT_HTTPS=audit    report only, never write
#   NEOHIRO_APT_HTTPS=0        disable entirely
#   NEOHIRO_APT_HTTPS_REWRITE=1  allow http->https rewrite on non-apt families
#   NEOHIRO_APT_HTTPS_NOVERIFY=1 skip the post-rewrite `apt-get update` check
#   NEOHIRO_APT_BLOCK_PORT80=1 add `ufw deny out 80/tcp`
#   NEOHIRO_APT_ETC_DIR=path   relocate the /etc tree (used by the tests)
#   NEOHIRO_APT_BACKUP_DIR=path relocate the backup tree (used by the tests)
#
# Usage:
#   source lib/apt-https.sh
#   apt_https_guard            # idempotent, once per process; use in hot paths
#   apt_https_enforce          # force a full pass (menus / CLI)
#   apt_https_report           # read-only status; rc 0 = all repos are https
#   apt_https_revert           # restore every backup taken by this lib
#
# Bash 4.0+ is required, matching the rest of the repo.

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf '%s\n' "lib/apt-https.sh requires Bash 4.0+; found ${BASH_VERSION:-unknown}." >&2
  return 1 2>/dev/null || exit 1
fi

# Guard against double-sourcing.
[ -n "${__NEOHIRO_APT_HTTPS_INIT:-}" ] && return 0 2>/dev/null || true
__NEOHIRO_APT_HTTPS_INIT=1

# Re-entrancy / once-per-process latch.  Set BEFORE any work so a nested
# call (e.g. the verification `apt-get update` re-entering pkg_update)
# short-circuits instead of recursing.
_APT_HTTPS_DONE="${_APT_HTTPS_DONE:-}"

# Print helpers.  Reuse the host's when available, otherwise define
# self-contained fallbacks so this file works standalone.
if ! declare -F _c >/dev/null 2>&1; then
  _c() { if [ "${USE_COLOR:-0}" = "1" ]; then printf '\033[%s%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '  %s\n' "$*"; }
fi
if ! declare -F msg >/dev/null 2>&1; then
  msg() { echo "=> $*"; }
fi
if ! declare -F ok >/dev/null 2>&1; then
  ok() { printf '%s %s\n' "$(_c '1;32m' '[OK]')" "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '%s %s\n' "$(_c '1;33m' '[WARNING]')" "$*" >&2; }
fi
if ! declare -F err >/dev/null 2>&1; then
  err() { printf '%s %s\n' "$(_c '1;31m' '[ERROR]')" "$*" >&2; }
fi

# ── Paths ────────────────────────────────────────────────────────────────────

APT_HTTPS_CONF_NAME="99neohiro-force-https"

apt_https_etc_dir() {
  printf '%s' "${NEOHIRO_APT_ETC_DIR:-/etc}"
}

apt_https_backup_dir() {
  printf '%s' "${NEOHIRO_APT_BACKUP_DIR:-/var/backups/neohiro-apt-https}"
}

# _apt_https_conf_file — absolute path of the managed apt policy drop-in.
apt_https_conf_file() {
  printf '%s' "$(apt_https_etc_dir)/apt/apt.conf.d/${APT_HTTPS_CONF_NAME}"
}

# ── Privilege / dry-run plumbing ─────────────────────────────────────────────

_apt_https_is_root() {
  [ "${EUID:-$(id -u 2>/dev/null || echo 1000)}" = "0" ]
}

# _apt_priv <cmd...> — run a privileged command, honouring DRY_RUN.
# Returns 1 when privileges are unavailable so callers can degrade.
_apt_priv() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '  DRY: %s\n' "$*"
    return 0
  fi
  if _apt_https_is_root; then
    "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi
  return 1
}

# _apt_https_privileged_ok — true when we can actually write to /etc.
_apt_https_privileged_ok() {
  _apt_https_is_root && return 0
  command -v sudo >/dev/null 2>&1 && return 0
  return 1
}

# ── Family detection ─────────────────────────────────────────────────────────
# Same precedence as detect_distro() in linuxinstall.sh and pkg_mgr() in
# DeepClean.sh: pacman -> zypper -> dnf -> yum -> apt.
#
# NEOHIRO_APT_FAMILY pins the result. That is what lets the test suite (and
# a CI container running a foreign base image) exercise the apt, dnf,
# zypper, pacman and "none" code paths deterministically.

apt_https_family() {
  if [ -n "${NEOHIRO_APT_FAMILY:-}" ]; then
    printf '%s' "$NEOHIRO_APT_FAMILY"
    return 0
  fi
  if command -v pacman >/dev/null 2>&1 && [ -f /etc/pacman.conf ]; then
    printf 'pacman'
  elif command -v zypper >/dev/null 2>&1; then
    printf 'zypper'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  elif command -v apt-get >/dev/null 2>&1 || [ -f /etc/apt/sources.list ]; then
    printf 'apt'
  else
    printf 'none'
  fi
}

# ── Repo file discovery ──────────────────────────────────────────────────────

# _apt_https_repo_files — one repo-definition path per line (apt only).
_apt_https_repo_files() {
  local etc f
  etc="$(apt_https_etc_dir)"
  [ -f "${etc}/apt/sources.list" ] && printf '%s\n' "${etc}/apt/sources.list"
  for f in "${etc}"/apt/sources.list.d/*.list "${etc}"/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# _apt_https_foreign_repo_files <family> — repo definitions for the other
# families, so the audit has something to read even when the detected family
# is different (dual-boot / container with a foreign sources dir).
_apt_https_foreign_repo_files() {
  local etc f d
  etc="$(apt_https_etc_dir)"
  case "$1" in
    dnf|yum)
      for f in "${etc}"/yum.repos.d/*.repo; do [ -f "$f" ] && printf '%s\n' "$f"; done
      ;;
    zypper)
      for f in "${etc}"/zypp/repos.d/*.repo; do [ -f "$f" ] && printf '%s\n' "$f"; done
      ;;
    pacman)
      for f in "${etc}"/pacman.d/*; do [ -f "$f" ] && printf '%s\n' "$f"; done
      ;;
    *) : ;;
  esac
  return 0
}

# ── Plaintext detection ──────────────────────────────────────────────────────

# _apt_https_plaintext_in_apt_file <file>
# Prints the offending (line-number + trimmed-line) pairs.  DEB822 files are
# matched on the URIs: field only, so a commented-out http:// note never
# counts.  Classic files skip comment lines entirely.
_apt_https_plaintext_in_apt_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  case "$f" in
    *.sources)
      awk '/^[[:space:]]*URIs:[[:space:]]/ && /http:\/\// {
               gsub(/^[[:space:]]+/, "", $0); printf "%s:%d: %s\n", FILENAME, NR, $0 }' "$f" 2>/dev/null
      ;;
    *)
      awk '/^[[:space:]]*#/ { next } /http:\/\// {
               gsub(/^[[:space:]]+/, "", $0); printf "%s:%d: %s\n", FILENAME, NR, $0 }' "$f" 2>/dev/null
      ;;
  esac
  return 0
}

# _apt_https_plaintext_in_repo_file <file> <pattern>
# Generic scan for the yum/dnf/zypper/pacman repo layouts.  $2 is an ERE
# applied per line; the line must also contain http:// to be reported.
_apt_https_plaintext_in_repo_file() {
  local f="$1" pat="$2"
  [ -f "$f" ] || return 0
  awk -v pat="$pat" '
    /^[[:space:]]*#/ { next }
    $0 ~ pat && /http:\/\// {
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      printf "%s:%d: %s\n", FILENAME, NR, line
    }' "$f" 2>/dev/null
  return 0
}

# ── Backups ──────────────────────────────────────────────────────────────────

# _apt_https_backup_path <file> — deterministic, path-flattened backup name.
_apt_https_backup_path() {
  local flat
  flat="$(printf '%s' "$1" | tr '/' '_')"
  printf '%s/%s.orig' "$(apt_https_backup_dir)" "$flat"
}

# _apt_https_backup_once <file> — copy <file> aside the first time we touch it.
_apt_https_backup_once() {
  local src="$1" dst
  [ -f "$src" ] || return 0
  dst="$(_apt_https_backup_path "$src")"
  [ -f "$dst" ] && return 0
  _apt_priv mkdir -p "$(apt_https_backup_dir)" || return 1
  if ! _apt_priv cp -p "$src" "$dst"; then
    warn "Could not back up $src — refusing to edit it."
    return 1
  fi
  # Hook into the host's rollback log when one exists so `linuxinstall.sh
  # --rollback` can undo this too.
  if declare -F record_backup >/dev/null 2>&1; then
    record_backup "$src" "$dst" 2>/dev/null || true
  fi
  info "Backed up $src -> $dst"
  return 0
}

# ── apt policy drop-in ───────────────────────────────────────────────────────

# _apt_https_write_conf — install the managed apt.conf.d policy file.
# Idempotent: byte-identical content is left alone (no backup churn).
_apt_https_write_conf() {
  local conf tmp rc
  conf="$(apt_https_conf_file)"
  tmp="$(_apt_https_stage)"
  {
    printf '%s\n' '// Managed by neohiro/linux (lib/apt-https.sh). Do not edit.'
    printf '%s\n' '// Re-running the installer overwrites this file safely;'
    printf '%s\n' '// `bash linuxinstall.sh --apt-https-off` removes it.'
    printf '%s\n' ''
    printf '%s\n' '// Prefer TLS, and never silently downgrade to plaintext.'
    printf '%s\n' 'Acquire::https::AllowRedirect "true";'
    printf '%s\n' 'Acquire::http::AllowRedirect "false";'
    printf '%s\n' 'Acquire::ftp::AllowRedirect "false";'
    printf '%s\n' ''
    printf '%s\n' '// Authenticate the mirror, not just the channel.'
    printf '%s\n' 'Acquire::https::Verify-Peer "true";'
    printf '%s\n' 'Acquire::https::Verify-Host "true";'
    printf '%s\n' ''
    printf '%s\n' '// Transparent mirrors usually need more than one try.'
    printf '%s\n' 'Acquire::Retries "3";'
    printf '%s\n' ''
    printf '%s\n' '// Pin a corporate proxy by uncommenting and editing:'
    printf '%s\n' '// Acquire::http::Proxy  "http://proxy.corp.example:3128";'
    printf '%s\n' '// Acquire::https::Proxy "http://proxy.corp.example:3128";'
  } > "$tmp"
  # Already correct?  Then there is nothing to do.
  if [ -f "$conf" ] && cmp -s "$tmp" "$conf"; then
    rm -f "$tmp"
    return 0
  fi
  if ! _apt_https_backup_once "$conf"; then
    rm -f "$tmp"
    return 1
  fi
  _apt_priv mkdir -p "$(apt_https_etc_dir)/apt/apt.conf.d" || { rm -f "$tmp"; return 1; }
  if ! _apt_priv install -m 0644 "$tmp" "$conf"; then
    # `install` is not present on every minimal image; fall back to cp+chmod.
    if _apt_priv cp "$tmp" "$conf" && _apt_priv chmod 0644 "$conf"; then
      rc=0
    else
      rc=1
    fi
  else
    rc=0
  fi
  rm -f "$tmp"
  [ "$rc" = "0" ] || return 1
  info "apt policy: $conf"
  return 0
}

# _apt_https_stage — private scratch path for generated files.
_apt_https_stage() {
  if declare -F _tmpfile >/dev/null 2>&1; then
    _tmpfile apt-https
    return 0
  fi
  mktemp "${TMPDIR:-/tmp}/neohiro-apt-https.XXXXXX"
}

# ── apt source rewriting ─────────────────────────────────────────────────────
#
# The three functions below report their result through globals
# (_APT_HTTPS_VERDICT / _APT_HTTPS_CHANGED / _APT_HTTPS_REVERTED) instead of
# stdout.  They emit progress messages of their own, and a command
# substitution would fold that text into the value it returns -- which then
# lands inside an arithmetic expansion and turns a word like "Restored" into
# a variable lookup. Globals keep the two channels separate.

_APT_HTTPS_VERDICT=""
_APT_HTTPS_CHANGED=0
_APT_HTTPS_REVERTED=0
# Files that DID contain plaintext but could not be rewritten (no writable
# backup, or the privileged copy failed). Tracked separately so
# apt_https_enforce never claims "already https" when it actually gave up.
_APT_HTTPS_REFUSED=0

# _apt_https_rewrite_file <file>
# Sets _APT_HTTPS_VERDICT to "changed" or "clean". Backs the file up before
# the first edit and refuses to edit a file it could not back up.
_apt_https_rewrite_file() {
  local f="$1" tmp expr
  _APT_HTTPS_VERDICT="clean"
  [ -f "$f" ] || return 0

  case "$f" in
    *.sources) expr='/^[[:space:]]*URIs:[[:space:]]/ s|http://|https://|g' ;;
    *)         expr='/^[[:space:]]*#/! s|http://|https://|g' ;;
  esac

  tmp="$(_apt_https_stage)"
  if ! sed -E "$expr" "$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    _APT_HTTPS_REFUSED=$((_APT_HTTPS_REFUSED + 1))
    return 0
  fi
  if cmp -s "$tmp" "$f"; then
    rm -f "$tmp"
    return 0
  fi
  # Refuse to edit anything we cannot first back up or cannot write.
  if ! _apt_https_backup_once "$f"; then
    rm -f "$tmp"
    _APT_HTTPS_REFUSED=$((_APT_HTTPS_REFUSED + 1))
    return 0
  fi
  if ! _apt_priv cp "$tmp" "$f"; then
    rm -f "$tmp"
    _APT_HTTPS_REFUSED=$((_APT_HTTPS_REFUSED + 1))
    return 0
  fi
  rm -f "$tmp"
  _APT_HTTPS_VERDICT="changed"
  return 0
}

# _apt_https_rewrite_apt_sources — rewrite every apt repo definition.
# Sets _APT_HTTPS_CHANGED to the number of files rewritten.
_apt_https_rewrite_apt_sources() {
  local f
  _APT_HTTPS_CHANGED=0
  _APT_HTTPS_REFUSED=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _apt_https_rewrite_file "$f"
    if [ "$_APT_HTTPS_VERDICT" = "changed" ]; then
      _APT_HTTPS_CHANGED=$((_APT_HTTPS_CHANGED + 1))
      info "Rewrote plaintext repo URLs -> https: $f"
    fi
  done < <(_apt_https_repo_files)
  return 0
}

# _apt_https_revert_apt_sources — undo the rewrite from the backups.
# Sets _APT_HTTPS_REVERTED to the number of files restored.
_apt_https_revert_apt_sources() {
  local f bak backupdir
  _APT_HTTPS_REVERTED=0
  backupdir="$(apt_https_backup_dir)"
  [ -d "$backupdir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bak="$(_apt_https_backup_path "$f")"
    if [ -f "$bak" ] && ! cmp -s "$bak" "$f"; then
      if _apt_priv cp "$bak" "$f"; then
        _APT_HTTPS_REVERTED=$((_APT_HTTPS_REVERTED + 1))
        info "Restored $f from backup"
      fi
    fi
  done < <(_apt_https_repo_files)
  return 0
}

# ── Non-apt audit / optional rewrite ─────────────────────────────────────────

_DNF_URL_RE='^([[:space:]]*)(baseurl|metalink|mirrorlist)[[:space:]]*='
_ZYPPER_URL_RE='^([[:space:]]*)(baseurl|uri|mirrorlist)[[:space:]]*='
_PACMAN_URL_RE='^([[:space:]]*)Server[[:space:]]*='

# _apt_https_audit_family <family> — print plaintext repo lines.
_apt_https_audit_family() {
  local fam="$1" f
  case "$fam" in
    apt)
      while IFS= read -r f; do
        [ -n "$f" ] && _apt_https_plaintext_in_apt_file "$f"
      done < <(_apt_https_repo_files)
      ;;
    dnf|yum)
      while IFS= read -r f; do
        [ -n "$f" ] && _apt_https_plaintext_in_repo_file "$f" "$_DNF_URL_RE"
      done < <(_apt_https_foreign_repo_files "$fam")
      ;;
    zypper)
      while IFS= read -r f; do
        [ -n "$f" ] && _apt_https_plaintext_in_repo_file "$f" "$_ZYPPER_URL_RE"
      done < <(_apt_https_foreign_repo_files "$fam")
      ;;
    pacman)
      while IFS= read -r f; do
        [ -n "$f" ] && _apt_https_plaintext_in_repo_file "$f" "$_PACMAN_URL_RE"
      done < <(_apt_https_foreign_repo_files "$fam")
      ;;
    *) : ;;
  esac
  return 0
}

# _apt_https_rewrite_family <family> — opt-in http->https for non-apt
# families (NEOHIRO_APT_HTTPS_REWRITE=1).
# Sets _APT_HTTPS_CHANGED to the number of files rewritten.
_apt_https_rewrite_family() {
  local fam="$1" f
  _APT_HTTPS_CHANGED=0
  case "$fam" in
    dnf|yum|zypper|pacman) : ;;
    *) return 0 ;;
  esac
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _apt_https_rewrite_file "$f"
    [ "$_APT_HTTPS_VERDICT" = "changed" ] && _APT_HTTPS_CHANGED=$((_APT_HTTPS_CHANGED + 1))
  done < <(_apt_https_foreign_repo_files "$fam")
  return 0
}

# ── flatpak remotes ──────────────────────────────────────────────────────────

_apt_https_flatpak_plaintext() {
  command -v flatpak >/dev/null 2>&1 || return 0
  flatpak remotes --show-details 2>/dev/null | awk '/http:\/\// { print }' || true
  return 0
}

# ── ca-certificates sanity check ─────────────────────────────────────────────

# HTTPS verification is worthless without a trust store.  Warn (never fail)
# when it is missing, because installing it would itself need a download.
_apt_https_check_ca_certs() {
  local fam="$1" p
  case "$fam" in
    apt)
      if [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ]; then
        return 0
      fi
      p="ca-certificates"
      ;;
    dnf|yum) [ -e /etc/pki/tls/certs/ca-bundle.crt ] && return 0; p="ca-certificates" ;;
    zypper)  [ -e /etc/ssl/ca-bundle.pem ] && return 0;    p="ca-certificates" ;;
    pacman)  [ -e /etc/ssl/certs/ca-certificates.crt ] && return 0; p="ca-certificates" ;;
    *)       return 0 ;;
  esac
  warn "No system CA trust store found. HTTPS verification of packages will fail."
  info "Install '$p' after the sources are trusted, then re-run: apt_https_enforce"
  return 1
}

# ── Optional outbound port-80 block ──────────────────────────────────────────

# _apt_https_block_port80 — belt-and-braces so no process can open an
# unencrypted repo connection.  Opt-in (NEOHIRO_APT_BLOCK_PORT80=1) because a
# blanket outbound block also affects unrelated plaintext protocols.
_apt_https_block_port80() {
  [ "${NEOHIRO_APT_BLOCK_PORT80:-0}" = "1" ] || return 0
  if ! command -v ufw >/dev/null 2>&1; then
    if command -v firewall-cmd >/dev/null 2>&1; then
      warn "NEOHIRO_APT_BLOCK_PORT80=1 but only firewalld is present."
      info "firewalld needs an explicit rich rule; skipping to avoid locking yourself out."
    else
      warn "NEOHIRO_APT_BLOCK_PORT80=1 but no UFW/firewalld found; skipping."
    fi
    return 0
  fi
  if ufw status 2>/dev/null | grep -qE '^80/tcp[[:space:]]+DENY[[:space:]]+OUT'; then
    info "ufw already denies outbound 80/tcp"
    return 0
  fi
  # Refuse while plaintext repos remain: the block would break them anyway.
  if [ -n "$(apt_https_status_text)" ]; then
    warn "Skipping the port-80 block: plaintext repos are still configured."
    info "Fix them first (see the report above), then re-run with NEOHIRO_APT_BLOCK_PORT80=1."
    return 0
  fi
  if _apt_priv ufw deny out 80/tcp; then
    ok "Blocked outbound TCP/80 (apt traffic is HTTPS-only from now on)."
    info "Undo: sudo ufw delete deny out 80/tcp"
  else
    warn "Could not add the ufw outbound 80/tcp deny rule."
  fi
  return 0
}

# ── Status / report ──────────────────────────────────────────────────────────

# apt_https_status_text — every plaintext repo line still configured.
apt_https_status_text() {
  local fam
  fam="$(apt_https_family)"
  _apt_https_audit_family "$fam"
  _apt_https_flatpak_plaintext
  return 0
}

# apt_https_report — human-readable state summary.
# Returns 0 when everything is https, 1 when plaintext remains, 2 when the
# family is unknown.
apt_https_report() {
  local fam missing conf findings
  fam="$(apt_https_family)"
  printf '\n%s\n' "$(_c '1;36m' '━━━ Package transport security (HTTPS) ━━━')"
  printf '  Detected package manager: %s\n' "$fam"

  case "$fam" in
    apt)
      conf="$(apt_https_conf_file)"
      if [ -f "$conf" ]; then
        printf '  %s %s\n' "$(_c '1;32m' '[x]')" "apt policy drop-in active: $conf"
      else
        printf '  %s %s\n' "$(_c '1;31m' '[ ]')" "apt policy drop-in MISSING: $conf"
      fi
      ;;
    dnf|yum)   printf '  %s\n' "dnf/yum: repo files audited (no blind rewrite)." ;;
    zypper)    printf '  %s\n' "zypper: repo files audited (no blind rewrite)." ;;
    pacman)    printf '  %s\n' "pacman: mirrorlist audited (no blind rewrite)." ;;
    *)         printf '  %s\n' "No supported package manager detected." ;;
  esac

  findings="$(apt_https_status_text)"
  if [ -n "$findings" ]; then
    printf '\n  %s\n' "$(_c '1;33m' 'Plaintext (http://) repository entries still present:')"
    printf '%s\n' "$findings" | sed 's/^/    /'
    printf '\n  %s\n' "  apt:    fix with  sudo bash linuxinstall.sh --apt-https"
    printf '%s\n' "  others: set NEOHIRO_APT_HTTPS_REWRITE=1, then re-run the audit"
  else
    printf '\n  %s %s\n' "$(_c '1;32m' '[x]')" "No plaintext repository URLs detected."
  fi
  _apt_https_check_ca_certs "$fam" || true
  printf '\n'

  if [ "$fam" = "none" ]; then return 2; fi
  [ -n "$findings" ] && return 1
  return 0
}

# ── Enforce ──────────────────────────────────────────────────────────────────

# _apt_https_verify_apt_sources — run a real `apt-get update` and roll back
# the rewrite if the mirrors turned out not to speak https.
_apt_https_verify_apt_sources() {
  [ "${NEOHIRO_APT_HTTPS_NOVERIFY:-0}" = "1" ] && return 0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  command -v apt-get >/dev/null 2>&1 || return 0

  info "Verifying the rewritten sources with a real apt-get update..."
  if _apt_priv env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    ok "All apt repositories answered over HTTPS."
    return 0
  fi
  if [ "${NEOHIRO_APT_HTTPS_STRICT:-0}" = "1" ]; then
    err "apt-get update failed after the https rewrite and NEOHIRO_APT_HTTPS_STRICT=1."
    err "Nothing was rolled back. Fix the repo URLs, or re-run with --apt-https-off."
    return 1
  fi
  warn "apt-get update failed after the https rewrite — rolling back to the backups."
  _apt_https_revert_apt_sources >/dev/null
  warn "Reverted. A mirror does not serve the same paths over HTTPS."
  info "Repoint that repo at an https-capable mirror, then re-run --apt-https."
  return 1
}

# apt_https_enforce [label] — apply the precaution once, unconditionally.
# [label] is a short breadcrumb describing the caller, e.g. "pkg_install".
apt_https_enforce() {
  local label="${1:-enforce}" mode fam conf_failed findings rc=0
  mode="${NEOHIRO_APT_HTTPS:-1}"

  fam="$(apt_https_family)"
  if [ "$fam" = "none" ]; then
    info "No supported package manager detected — HTTPS guard not applicable."
    return 0
  fi

  if [ "$mode" = "0" ]; then
    info "NEOHIRO_APT_HTTPS=0 — repository transport guard disabled ($label)."
    return 0
  fi

  msg "Repository transport guard ($label): $fam"

  if [ "$mode" = "audit" ]; then
    info "NEOHIRO_APT_HTTPS=audit — reporting only, nothing is modified."
    apt_https_report || true
    return 0
  fi

  if ! _apt_https_privileged_ok; then
    warn "Not root and no sudo available — cannot enforce HTTPS for repositories."
    info "Re-run as root, or set NEOHIRO_APT_HTTPS=0 to silence this."
    return 0
  fi

  case "$fam" in
    apt)
      conf_failed=0
      _apt_https_write_conf || conf_failed=1
      _apt_https_rewrite_apt_sources
      if [ "$_APT_HTTPS_CHANGED" -gt 0 ]; then
        ok "Rewrote $_APT_HTTPS_CHANGED apt source file(s) to https://"
        _apt_https_verify_apt_sources || rc=1
      elif [ "$_APT_HTTPS_REFUSED" -gt 0 ]; then
        warn "Could not rewrite $_APT_HTTPS_REFUSED apt source file(s): no writable backup."
        info "Check that $(apt_https_backup_dir) is writable by root, then re-run."
        rc=1
      else
        ok "apt repositories already use https://"
      fi
      if [ "$conf_failed" = "1" ]; then
        warn "Could not install the apt policy drop-in."
        rc=1
      fi
      ;;
    dnf|yum|zypper|pacman)
      if [ "${NEOHIRO_APT_HTTPS_REWRITE:-0}" = "1" ]; then
        _apt_https_rewrite_family "$fam"
        if [ "$_APT_HTTPS_CHANGED" -gt 0 ]; then
          ok "Rewrote $_APT_HTTPS_CHANGED $fam repo file(s) to https:// (NEOHIRO_APT_HTTPS_REWRITE=1)"
          info "Re-check with --apt-https-audit; not every mirror serves the same paths over TLS."
        fi
      fi
      ;;
    *) : ;;
  esac

  # A verification failure rolls the rewrite back; report whatever remains.
  findings="$(apt_https_status_text)"
  if [ -n "$findings" ]; then
    warn "Plaintext repository URLs remain for $fam:"
    printf '%s\n' "$findings" | sed 's/^/    /'
    if [ "$fam" != "apt" ]; then
      info "Point those at an https-capable mirror, or opt in to a blind rewrite"
      info "with NEOHIRO_APT_HTTPS_REWRITE=1 (verify afterwards)."
      [ "${NEOHIRO_APT_HTTPS_STRICT:-0}" = "1" ] && rc=1
    fi
  fi

  _apt_https_check_ca_certs "$fam" || true
  _apt_https_block_port80
  return "$rc"
}

# apt_https_guard [label] — hot-path wrapper.  Enforces at most once per
# process so every package entry point can call it unconditionally.
#
# It always returns 0. A guard must never be the reason a package operation
# fails: call sites are things like `pkg_install`, which run under `set -e`
# in some of the standalone scripts, and a non-zero return there would abort
# the caller before it ever reached the package manager. Enforcement failures
# are reported through apt_https_report and the enforce exit status, not by
# failing the hot path.
apt_https_guard() {
  [ -n "$_APT_HTTPS_DONE" ] && return 0
  # Latch first: the verification `apt-get update` below can re-enter the
  # package layer, which must not recurse.
  _APT_HTTPS_DONE=1
  apt_https_enforce "${1:-guard}" || true
  return 0
}

# apt_https_revert — undo everything this lib changed.
apt_https_revert() {
  local conf n
  conf="$(apt_https_conf_file)"
  _apt_https_revert_apt_sources
  n="$_APT_HTTPS_REVERTED"
  if [ -f "$conf" ] && [ -f "$(_apt_https_backup_path "$conf")" ]; then
    if _apt_priv cp "$(_apt_https_backup_path "$conf")" "$conf"; then
      info "Restored $conf from backup"
    fi
  elif [ -f "$conf" ]; then
    # No backup means we created it: removing it is the correct revert.
    if _apt_priv rm -f "$conf"; then
      ok "Removed $conf"
    fi
  fi
  if [ "$_APT_HTTPS_REVERTED" -gt 0 ] 2>/dev/null; then
    ok "Reverted $_APT_HTTPS_REVERTED repository file(s) to their pre-guard contents."
  fi
  _APT_HTTPS_DONE=""
  ok "Repository transport guard disabled."
  return 0
}

# ── Standalone entry point ───────────────────────────────────────────────────
#   sudo bash lib/apt-https.sh            enforce
#   sudo bash lib/apt-https.sh --report   audit only
#   sudo bash lib/apt-https.sh --revert   undo
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  # Standalone: this file sets no `set -e`, but capture the status anyway so
  # the documented exit-code contract (0 = clean, 1 = plaintext remains,
  # 2 = no package manager) is explicit rather than an accident of which
  # command happened to run last.
  _ap_https_rc=0
  case "${1:---enforce}" in
    --report|--audit) apt_https_report || _ap_https_rc=$? ;;
    --revert)         apt_https_revert || _ap_https_rc=$? ;;
    --enforce)        apt_https_enforce "cli" || _ap_https_rc=$? ;;
    *) printf 'usage: bash lib/apt-https.sh [--enforce|--report|--revert]\n' >&2
       _ap_https_rc=2 ;;
  esac
  exit "$_ap_https_rc"
fi