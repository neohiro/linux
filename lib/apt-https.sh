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

# _apt_https_plaintext_generic <file> <source-id>
#
# The format-agnostic detector: any non-comment line carrying an http:// URL.
# Used for every non-apt store (apk repositories, docker daemon.json, pip.conf,
# .npmrc, cargo config.toml, .gemrc, nix.conf, fwupd remotes, ...).
#
# Being generic is the point. A per-dialect key list would miss gpgkey=,
# metalink=, and whatever the next distro release adds, and a miss is exactly
# the failure this library exists to prevent.
#
# One deliberate exception: JSON has no comment syntax, so skipping "#" lines
# cannot distinguish a doc link from a fetch target. In a .json file we
# therefore require http:// to sit at the start of a JSON string, which is
# where a URL value lives. Without this, docker daemon.json entries like
# {"_comment": "see http://docs.internal"} would be reported as plaintext
# registries and train users to ignore the report.
_apt_https_plaintext_generic() {
  local f="$1" id="${2:-}"
  [ -f "$f" ] || return 0
  case "$f" in
    *.json)
      awk '
        /"http:\/\// {
          line = $0
          gsub(/^[[:space:]]+/, "", line)
          printf "%s:%d: %s\n", FILENAME, NR, line
        }' "$f" 2>/dev/null
      ;;
    *)
      awk '
        /^[[:space:]]*(#|;)/ { next }
        /http:\/\// {
          line = $0
          gsub(/^[[:space:]]+/, "", line)
          printf "%s:%d: %s\n", FILENAME, NR, line
        }' "$f" 2>/dev/null
      ;;
  esac
  return 0
}

# _apt_https_rewrite_generic <file> — http:// -> https:// on non-comment lines.
# Same substitution the apt rewrite uses, so behaviour is identical.
_APT_HTTPS_GENERIC_RE='/^[[:space:]]*(#|;)/! s|http://|https://|g'

# ── Backups ──────────────────────────────────────────────────────────────────

# _apt_https_backup_path <file> — deterministic, collision-resistant name.
#
# The path is flattened so it is a legal filename inside the backup
# directory, but flattening alone is NOT injective: /a/b/c and /a_b/c both
# become _a_b_c. A collision here means reverting one file restores another
# file's contents, which is a silent, hard-to-trace corruption of a package
# manager. So append a checksum of the real path.
#
# cksum (POSIX) is used rather than a shell hash so the value is stable
# across shells, runs, and machines -- these backups may be inspected or
# moved during an incident.
_apt_https_backup_path() {
  local flat sum
  flat="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  sum="$(printf '%s' "$1" | cksum 2>/dev/null | tr -d ' ' | cut -d' ' -f1)"
  if [ -n "$sum" ]; then
    printf '%s/%s-%s.orig' "$(apt_https_backup_dir)" "$flat" "$sum"
  else
    # cksum unavailable: the flattened name alone is still better than
    # hashing nothing, and this is recorded so it is not mistaken for a bug.
    printf '%s/%s.orig' "$(apt_https_backup_dir)" "$flat"
  fi
}

# _apt_https_backup_once <file> — copy <file> aside the first time we touch it.
#
# The copy is staged inside the backup directory and renamed into place, for
# the same reason the rewrite is: `cp` into a destination that does not exist
# yet leaves a truncated `.orig` if it dies partway. A truncated backup is
# worse than no backup, because `--apt-https-off` would then confidently
# restore a broken file. rename(2) means the backup is either absent or
# complete.
_apt_https_backup_once() {
  local src="$1" dst stage
  [ -f "$src" ] || return 0
  dst="$(_apt_https_backup_path "$src")"
  [ -f "$dst" ] && return 0
  _apt_priv mkdir -p "$(apt_https_backup_dir)" || return 1
  stage="${dst}.partial.$$"
  _apt_priv rm -f "$stage" 2>/dev/null || true
  if ! _apt_priv cp -p "$src" "$stage"; then
    _apt_priv rm -f "$stage" 2>/dev/null || true
    warn "Could not back up $src — refusing to edit it."
    return 1
  fi
  if ! _apt_priv mv -f "$stage" "$dst"; then
    _apt_priv rm -f "$stage" 2>/dev/null || true
    warn "Could not store the backup for $src — refusing to edit it."
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
  # Atomic rename into place; see _apt_https_atomic_replace for why.
  if _apt_https_atomic_replace "$conf" 0644 _apt_https_prep_conf_stage "$tmp"; then
    rc=0
  else
    rc=1
  fi
  rm -f "$tmp"
  [ "$rc" = "0" ] || return 1
  info "apt policy: $conf"
  return 0
}

# apt_https_available — is the real guard loaded?
#
# Callers that infer "the repositories are fine" from an empty
# apt_https_status_text must check this first. When the library cannot be
# loaded, a stub takes its place and status_text returns empty for "found
# nothing" -- indistinguishable from "checked, all https". Reporting that as
# verified would be an unverified security claim printed as fact.
apt_https_available() {
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

# _apt_https_atomic_replace <target> <mode|-> <prep-fn> [prep-args...]
#
# Runs <prep-fn> <stage> [prep-args...] to build a staging file that lives
# in the *target's own directory*, then renames it over the target.
#
# Why not just `cp tmp target`: cp truncates the destination and then
# writes. If the process dies mid-copy — OOM, SIGKILL, a container being
# stopped — the repo file is left truncated, i.e. a broken package manager.
# rename(2) within a single filesystem is atomic, so a reader (apt itself,
# or a concurrent run of this script) sees either the whole old file or the
# whole new one, never a half-written mix. Staging in the target's own
# directory guarantees the same filesystem, which is what makes the rename
# atomic instead of a slow cross-device copy.
#
# The staging name ends in the PID and therefore never ends in ".list" or
# ".sources", so apt's own sources.list.d globs cannot pick it up.
#
# <mode> is a chmod mode for the result ("-" = leave it alone, which is how
# the repo rewrite preserves the original file's mode and ownership).
_apt_https_atomic_replace() {
  local target="$1" mode="$2" prep="$3"; shift 3
  local stage
  stage="${target}.neohiro-rewrite.$$"
  _apt_priv rm -f "$stage" 2>/dev/null || true
  if ! "$prep" "$stage" "$@"; then
    _apt_priv rm -f "$stage" 2>/dev/null || true
    return 1
  fi
  if [ "$mode" != "-" ]; then
    if ! _apt_priv chmod "$mode" "$stage"; then
      _apt_priv rm -f "$stage" 2>/dev/null || true
      return 1
    fi
  fi
  if ! _apt_priv mv -f "$stage" "$target"; then
    _apt_priv rm -f "$stage" 2>/dev/null || true
    return 1
  fi
  return 0
}

# _apt_https_prep_conf_stage <stage> <src> — plain content copy.
_apt_https_prep_conf_stage() {
  _apt_priv cp "$2" "$1"
}

# _apt_https_prep_repo_stage <stage> <target> <rewritten-content>
#
# Builds the staged rewrite so the renamed result keeps the original file's
# mode and ownership. `cp -p` clones those attributes onto the staging file,
# then `cp` over the *existing* staging file replaces only its content --
# POSIX only applies the source's permissions when cp CREATES the
# destination, so the cloned attributes survive.
#
# This deliberately avoids `sed -i`: whether GNU sed, busybox sed, or a BSD
# variant preserve the mode across an in-place edit is implementation
# detail, and this file is edited while root on a machine whose package
# manager must keep working.
_apt_https_prep_repo_stage() {
  _apt_priv cp -p "$2" "$1" && _apt_priv cp "$3" "$1"
}

# ── apt source rewriting ─────────────────────────────────────────────────────
#
# The rewriters below report their result through globals
# (_APT_HTTPS_VERDICT / _APT_HTTPS_CHANGED / _APT_HTTPS_REVERTED /
# _APT_HTTPS_REFUSED) instead of stdout. They emit progress messages of
# their own, and a command substitution would fold that text into the value
# it returns -- which then lands inside an arithmetic expansion and turns a
# word like "Restored" into a variable lookup. Globals keep the message
# channel and the value channel separate.

_APT_HTTPS_VERDICT=""
_APT_HTTPS_CHANGED=0
_APT_HTTPS_REVERTED=0
# Files that DID contain plaintext but could not be rewritten (no writable
# backup, or the privileged copy failed). Tracked separately so
# apt_https_enforce never claims "already https" when it actually gave up.
_APT_HTTPS_REFUSED=0
# Latch for the CA-trust-store warning, which would otherwise repeat once per
# call site (enforce AND report both check it). This MUST be initialised here,
# at the top level: a report-only run never calls the rewrite path, so
# initialising it inside a function left it unbound under `set -u`.
_APT_HTTPS_CA_WARNED=""

# _apt_https_rewrite_file <file>
# Sets _APT_HTTPS_VERDICT to "changed" or "clean". Backs the file up before
# the first edit and refuses to edit a file it could not back up.
_apt_https_rewrite_file() {
  local f="$1" tmp expr="${2:-}"
  _APT_HTTPS_VERDICT="clean"
  [ -f "$f" ] || return 0

  if [ -z "$expr" ]; then
    # DEB822 must only be rewritten on the URIs: field; everything else is a
    # flat key=value or URL-per-line format, where any active line counts.
    case "$f" in
      *.sources) expr='/^[[:space:]]*URIs:[[:space:]]/ s|http://|https://|g' ;;
      *)         expr="$_APT_HTTPS_GENERIC_RE" ;;
    esac
  fi

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
  # Refuse to edit anything we cannot first back up.
  if ! _apt_https_backup_once "$f"; then
    rm -f "$tmp"
    _APT_HTTPS_REFUSED=$((_APT_HTTPS_REFUSED + 1))
    return 0
  fi
  # Atomic replace that keeps the original file's mode and ownership.
  if ! _apt_https_atomic_replace "$f" - _apt_https_prep_repo_stage "$f" "$tmp"; then
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

# _apt_https_revert_all_sources — undo the rewrite for EVERY source, not just
# apt. Sets _APT_HTTPS_REVERTED to the number of files restored.
_apt_https_revert_all_sources() {
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
  done < <(_apt_https_managed_files)
  return 0
}

# Kept as an alias: the original name is referenced by the inline fallback and
# by callers that only ever touched apt.
_apt_https_revert_apt_sources() {
  _apt_https_revert_all_sources
}

# ── App-store source registry ────────────────────────────────────────────────
# The precaution is not apt-specific: every distribution and language has its
# own "app store", and several of them default to plaintext HTTP. This
# registry is the single list of every source this library inspects.
#
# Three per-source questions:
#   files  — where the transport is configured on disk
#   env    — where it is configured through the environment
#   family — the repo-file dialect (drives which keys hold URLs)
#
# Detection is deliberately generic: ANY non-comment line containing an
# http:// URL in one of those files is reported. Per-dialect key regexes
# (baseurl=, Server=, index-url, registry, substituters, ...) would miss
# gpgkey=, metalkink= and whatever the next release adds, and a miss is
# exactly the failure mode this library exists to prevent.
#
# Rewriting is a separate, opt-in step (see apt_https_enforce) because
# whether https://<same-host><same-path> actually exists is not knowable
# without a network round trip. Rewriting blind would turn a working mirror
# into a broken one, which is worse than the threat. apt is the exception:
# it is verified with a real `apt-get update` and rolled back on failure.

# _apt_https_source_ids — every source id, one per line.
_apt_https_source_ids() {
  printf '%s\n' \
    apt dnf yum zypper pacman apk \
    flatpak snap docker brew pip npm cargo gem nix fwupd
}

# _apt_https_source_label <id> — human name for the report.
_apt_https_source_label() {
  case "$1" in
    apt)     printf 'apt (Debian/Ubuntu/Mint/Pop!/Kali)' ;;
    dnf)     printf 'dnf (RHEL 8+/Fedora/Alma/Rocky)' ;;
    yum)     printf 'yum (CentOS 7/RHEL 7)' ;;
    zypper)  printf 'zypper (openSUSE/SLES)' ;;
    pacman)  printf 'pacman (Arch/Manjaro)' ;;
    apk)     printf 'apk (Alpine)' ;;
    flatpak) printf 'flatpak remotes' ;;
    snap)    printf 'snap (store)' ;;
    docker)  printf 'docker registry config' ;;
    brew)    printf 'Homebrew taps' ;;
    pip)     printf 'pip index' ;;
    npm)     printf 'npm registry' ;;
    cargo)   printf 'cargo registry' ;;
    gem)     printf 'gem sources' ;;
    nix)     printf 'nix substituters/channels' ;;
    fwupd)   printf 'fwupd remotes (LVFS)' ;;
    *)       printf '%s' "$1" ;;
  esac
}

# _apt_https_source_files <id> — config files that carry this source's URLs.
_apt_https_source_files() {
  local etc f home
  etc="$(apt_https_etc_dir)"
  home="${HOME:-}"
  case "$1" in
    apt)     _apt_https_repo_files ;;
    dnf|yum) _apt_https_foreign_repo_files dnf ;;
    zypper)  _apt_https_foreign_repo_files zypper ;;
    pacman)  _apt_https_foreign_repo_files pacman ;;
    # Alpine: one URL per line, http:// by default on many images.
    apk)
      [ -f "${etc}/apk/repositories" ] && printf '%s\n' "${etc}/apk/repositories"
      ;;
    # Registry mirrors / insecure-registries live in daemon.json.
    docker)
      [ -f "${etc}/docker/daemon.json" ] && printf '%s\n' "${etc}/docker/daemon.json"
      ;;
    # pip: system config plus the two variables that usually win.
    pip)
      for f in "${etc}/pip.conf" "${etc}/xdg/pip/pip.conf"; do
        [ -f "$f" ] && printf '%s\n' "$f"
      done
      # Per-user config only makes sense with a real HOME. Without this guard
      # an unset HOME builds "/.config/pip/pip.conf" -- a path at the
      # filesystem root, which would be probed and could match.
      if [ -n "$home" ]; then
        for f in "${home}/.pip/pip.conf" "${home}/.config/pip/pip.conf"; do
          [ -f "$f" ] && printf '%s\n' "$f"
        done
      fi
      ;;
    npm)
      [ -f "${etc}/npmrc" ] && printf '%s\n' "${etc}/npmrc"
      [ -n "$home" ] && [ -f "${home}/.npmrc" ] && printf '%s\n' "${home}/.npmrc"
      ;;
    cargo)
      if [ -n "$home" ] && [ -f "${home}/.cargo/config.toml" ]; then
        printf '%s\n' "${home}/.cargo/config.toml"
      fi
      [ -f "${etc}/cargo/config.toml" ] && printf '%s\n' "${etc}/cargo/config.toml"
      ;;
    gem)
      [ -f "${etc}/gemrc" ] && printf '%s\n' "${etc}/gemrc"
      [ -n "$home" ] && [ -f "${home}/.gemrc" ] && printf '%s\n' "${home}/.gemrc"
      ;;
    nix)
      [ -f "${etc}/nix/nix.conf" ] && printf '%s\n' "${etc}/nix/nix.conf"
      ;;
    fwupd)
      for f in "${etc}"/fwupd/remotes.d/*.conf; do
        [ -f "$f" ] && printf '%s\n' "$f"
      done
      ;;
    *) : ;;
  esac
  return 0
}

# _apt_https_source_env <id> — transport configured through the environment.
# Printed as "VAR=value" so the user gets a copy-pasteable fix.
_apt_https_source_env() {
  case "$1" in
    pip)
      [ -n "${PIP_INDEX_URL:-}" ]     && printf 'PIP_INDEX_URL=%s\n'     "$PIP_INDEX_URL"
      [ -n "${PIP_EXTRA_INDEX_URL:-}" ] && printf 'PIP_EXTRA_INDEX_URL=%s\n' "$PIP_EXTRA_INDEX_URL"
      ;;
    npm)
      [ -n "${NPM_CONFIG_REGISTRY:-}" ] && printf 'NPM_CONFIG_REGISTRY=%s\n' "$NPM_CONFIG_REGISTRY"
      [ -n "${npm_config_registry:-}" ] && printf 'npm_config_registry=%s\n' "$npm_config_registry"
      ;;
    cargo)
      [ -n "${CARGO_REGISTRIES_CRATES_IO_INDEX:-}" ] && \
        printf 'CARGO_REGISTRIES_CRATES_IO_INDEX=%s\n' "$CARGO_REGISTRIES_CRATES_IO_INDEX"
      ;;
    gem)
      [ -n "${GEM_SOURCE:-}" ] && printf 'GEM_SOURCE=%s\n' "$GEM_SOURCE"
      ;;
    brew)
      [ -n "${HOMEBREW_BREW_GIT_REMOTE:-}" ]  && printf 'HOMEBREW_BREW_GIT_REMOTE=%s\n' "$HOMEBREW_BREW_GIT_REMOTE"
      [ -n "${HOMEBREW_CORE_GIT_REMOTE:-}" ]  && printf 'HOMEBREW_CORE_GIT_REMOTE=%s\n' "$HOMEBREW_CORE_GIT_REMOTE"
      [ -n "${HOMEBREW_API_DOMAIN:-}" ]       && printf 'HOMEBREW_API_DOMAIN=%s\n' "$HOMEBREW_API_DOMAIN"
      [ -n "${HOMEBREW_ARTIFACT_DOMAIN:-}" ]  && printf 'HOMEBREW_ARTIFACT_DOMAIN=%s\n' "$HOMEBREW_ARTIFACT_DOMAIN"
      ;;
    *) : ;;
  esac
  return 0
}

# _apt_https_source_applicable <id> [family]
# False when this host has no such store, so the report does not list eleven
# N/A rows on a minimal box.
#
# The detected family is passed in by callers rather than re-probed here.
# apt_https_family costs up to five `command -v` PATH scans, and the report
# loop called it once per RPM/Arch store -- twice over, since the report and
# the per-source query each ran the loop. That is wasted work and a latent
# inconsistency: if PATH changed mid-run a store could be "applicable" in one
# pass and missing from the next, and the same file could be reported twice.
_apt_https_source_applicable() {
  local id="$1" fam="${2:-}"
  case "$id" in
    # Only the package manager actually present should be audited as such.
    dnf|yum|zypper|pacman)
      [ -n "$fam" ] || fam="$(apt_https_family)"
      [ "$fam" = "$id" ] || return 1
      ;;
    snap)
      command -v snap >/dev/null 2>&1 || return 1
      ;;
    flatpak)
      command -v flatpak >/dev/null 2>&1 || return 1
      ;;
    docker)
      command -v docker >/dev/null 2>&1 || return 1
      ;;
    brew)
      command -v brew >/dev/null 2>&1 || return 1
      ;;
    pip)
      command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1 || return 1
      ;;
    npm)
      command -v npm >/dev/null 2>&1 || return 1
      ;;
    cargo)
      command -v cargo >/dev/null 2>&1 || return 1
      ;;
    gem)
      command -v gem >/dev/null 2>&1 || return 1
      ;;
    apk)
      command -v apk >/dev/null 2>&1 || return 1
      ;;
    *) : ;;
  esac
  return 0
}

# _apt_https_source_hint <id> — one short line on how to fix this store.
#
# Printed only for stores that actually have a plaintext endpoint. Without it
# the report says "repoint at https" and leaves the reader to work out where
# that setting lives -- and for flatpak and snap there is no config file this
# library can rewrite at all, so the generic advice is actively misleading.
_apt_https_source_hint() {
  case "$1" in
    apt)     printf 'rewrite automatically:  sudo bash linuxinstall.sh --apt-https' ;;
    dnf|yum) printf 'edit baseurl=/metalink=/mirrorlist= under /etc/yum.repos.d/*.repo' ;;
    zypper)  printf 'edit baseurl=/uri= under /etc/zypp/repos.d/*.repo' ;;
    pacman)  printf 'edit Server= lines in /etc/pacman.d/mirrorlist' ;;
    apk)     printf 'rewrite with NEOHIRO_APT_HTTPS_REWRITE=1, or edit /etc/apk/repositories' ;;
    docker)  printf 'set registry-mirrors to https:// in /etc/docker/daemon.json, drop insecure-registries, then restart docker' ;;
    brew)    printf 'export HOMEBREW_API_DOMAIN / HOMEBREW_BREW_GIT_REMOTE with an https:// URL' ;;
    pip)     printf 'export PIP_INDEX_URL=https://... (and PIP_EXTRA_INDEX_URL) or fix pip.conf' ;;
    npm)     printf 'npm config set registry https://registry.npmjs.org/' ;;
    cargo)   printf 'set the crates-io registry to sparse+https:// in ~/.cargo/config.toml' ;;
    gem)     printf 'gem sources --remove <url> && gem sources --add https://rubygems.org/' ;;
    nix)     printf 'use substituters = https://cache.nixos.org in nix.conf' ;;
    # No operator-editable transport config; a URL rewrite cannot fix these.
    flatpak) printf 'flatpak remote-modify --url=https://... <remote>   (no config file to rewrite)' ;;
    snap)    printf 'snapd-managed store; cannot be repointed without a custom snapd build' ;;
    *)       : ;;
  esac
}

# _apt_https_source_plaintext <id> — report this source's plaintext endpoints.
_apt_https_source_plaintext() {
  local id="$1" f
  case "$id" in
    apt)
      while IFS= read -r f; do
        [ -n "$f" ] && _apt_https_plaintext_in_apt_file "$f"
      done < <(_apt_https_repo_files)
      ;;
    flatpak)
      _apt_https_flatpak_plaintext
      ;;
    *)
      while IFS= read -r f; do
        [ -n "$f" ] && _apt_https_plaintext_generic "$f" "$id"
      done < <(_apt_https_source_files "$id")
      ;;
  esac
  _apt_https_source_env "$id"
  return 0
}

# _apt_https_source_prefer_https <id>
# Rewrites http:// -> https:// on non-comment lines of every config file for
# this source. Sets _APT_HTTPS_CHANGED / _APT_HTTPS_REFUSED. Opt-in only,
# except for apt (see apt_https_enforce).
_apt_https_source_prefer_https() {
  local id="$1" f
  _APT_HTTPS_CHANGED=0
  _APT_HTTPS_REFUSED=0
  [ "$id" = "apt" ] && { _apt_https_rewrite_apt_sources; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _apt_https_rewrite_file "$f"
    if [ "$_APT_HTTPS_VERDICT" = "changed" ]; then
      _APT_HTTPS_CHANGED=$((_APT_HTTPS_CHANGED + 1))
      info "Rewrote plaintext URLs -> https: $f"
    fi
  done < <(_apt_https_source_files "$id")
  return 0
}

# _apt_https_managed_files — every file this library may have edited.
_apt_https_managed_files() {
  local id f
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] && printf '%s\n' "$f"
    done < <(_apt_https_source_files "$id")
  done < <(_apt_https_source_ids)
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
#
# Latched to once per process: apt_https_enforce and apt_https_report both
# check this, and the maintenance menu and --apt-https path call both, which
# used to print the identical warning two or three times in one run.
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
  [ -n "$_APT_HTTPS_CA_WARNED" ] && return 1
  _APT_HTTPS_CA_WARNED=1
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

# apt_https_status_text — every plaintext endpoint across every app store.
# One line per offending config line, plus "VAR=value" for env-configured
# transports, so the output is directly actionable.
apt_https_status_text() {
  local id fam
  fam="$(apt_https_family)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _apt_https_source_applicable "$id" "$fam" || continue
    _apt_https_source_plaintext "$id"
  done < <(_apt_https_source_ids)
  return 0
}

# _apt_https_plaintext_for <id> [family] — findings for one source only.
apt_https_plaintext_for() {
  _apt_https_source_applicable "$1" "${2:-}" || return 0
  _apt_https_source_plaintext "$1"
}

# apt_https_report — per-source state summary.
# Returns 0 when nothing anywhere uses plaintext, 1 when any source does,
# 2 when no package manager at all was detected.
apt_https_report() {
  local fam conf findings id label n clean
  fam="$(apt_https_family)"
  printf '\n%s\n' "$(_c '1;36m' '━━━ App-store transport security (HTTPS) ━━━')"
  printf '  %-34s %s\n' "Package manager:" "$fam"
  if [ "$fam" = "apt" ]; then
    conf="$(apt_https_conf_file)"
    if [ -f "$conf" ]; then
      printf '  %s %s\n' "$(_c '1;32m' '[x]')" "apt policy drop-in active: $conf"
    else
      printf '  %s %s\n' "$(_c '1;31m' '[ ]')" "apt policy drop-in MISSING: $conf"
    fi
  fi
  printf '\n  %s\n' "$(_c '1;37m' 'Store                           Result')"

  clean=1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _apt_https_source_applicable "$id" "$fam" || continue
    label="$(_apt_https_source_label "$id")"
    findings="$(apt_https_plaintext_for "$id" "$fam")"
    if [ -z "$findings" ]; then
      printf '  %-30s %s\n' "$label" "$(_c '1;32m' 'https only')"
    else
      n="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"
      printf '  %-30s %s\n' "$label" "$(_c '1;31m' "$n plaintext endpoint(s)")"
      printf '%s\n' "$findings" | sed 's/^/      /'
      printf '      %s\n' "$(_apt_https_source_hint "$id")"
      clean=0
    fi
  done < <(_apt_https_source_ids)

  _apt_https_check_ca_certs "$fam" || true

  printf '\n'
  if [ "$clean" = "1" ]; then
    printf '  %s %s\n' "$(_c '1;32m' '[x]')" "No plaintext endpoints in any configured app store."
  else
    printf '  %s %s\n' "$(_c '1;33m' '[!]')" "Some stores still fetch over plaintext HTTP."
    printf '  %s\n' "  Use the per-store hint above. apt needs nothing: --apt-https"
    printf '%s\n' "  rewrites it unattended (and rolls back if a mirror cannot speak"
    printf '%s\n' "  TLS). For the others, repoint the endpoint, or opt in to a blanket"
    printf '%s\n' "  rewrite with NEOHIRO_APT_HTTPS_REWRITE=1 and re-audit afterwards."
  fi
  printf '\n'

  if [ "$fam" = "none" ]; then return 2; fi
  [ "$clean" = "1" ] && return 0
  return 1
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
  local label="${1:-enforce}" mode fam conf_failed findings rc=0 rewrite id n
  mode="${NEOHIRO_APT_HTTPS:-1}"

  fam="$(apt_https_family)"
  if [ "$fam" = "none" ] && [ "$mode" != "audit" ]; then
    info "No supported package manager detected — HTTPS guard not applicable."
    return 0
  fi

  if [ "$mode" = "0" ]; then
    info "NEOHIRO_APT_HTTPS=0 — repository transport guard disabled ($label)."
    return 0
  fi

  msg "Repository transport guard ($label): package manager = $fam"

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

  # ---- automatic: apt only -------------------------------------------------
  # The one store we rewrite unattended, because a real `apt-get update` can
  # verify the result and roll the rewrite back if the mirror cannot speak TLS.
  if [ "$fam" = "apt" ]; then
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
  fi

  # ---- opt-in: every other store -------------------------------------------
  # Whether https://<same host><same path> exists is unknowable without a
  # network round trip, so this is never automatic.
  if [ "${NEOHIRO_APT_HTTPS_REWRITE:-0}" = "1" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ "$id" = "apt" ] && continue
      _apt_https_source_applicable "$id" "$fam" || continue
      _apt_https_source_prefer_https "$id"
      n="$_APT_HTTPS_CHANGED"
      if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
        ok "Rewrote $n $(_apt_https_source_label "$id") file(s) to https://"
      fi
      if [ "${_APT_HTTPS_REFUSED:-0}" -gt 0 ] 2>/dev/null; then
        warn "Could not rewrite $_APT_HTTPS_REFUSED $(_apt_https_source_label "$id") file(s): no writable backup."
      fi
    done < <(_apt_https_source_ids)
    info "Rewrote non-apt stores because NEOHIRO_APT_HTTPS_REWRITE=1."
    info "Re-audit with --apt-https-audit; not every mirror serves the same paths over TLS."
  fi

  # ---- report ---------------------------------------------------------------
  findings="$(apt_https_status_text)"
  if [ -n "$findings" ]; then
    warn "Plaintext endpoints still configured:"
    printf '%s\n' "$findings" | sed 's/^/    /'
    [ "$fam" = "apt" ] || info "Repoint these at an https:// endpoint, or opt in to a"
    [ "$fam" = "apt" ] || info "blind rewrite with NEOHIRO_APT_HTTPS_REWRITE=1."
    if [ "${NEOHIRO_APT_HTTPS_STRICT:-0}" = "1" ]; then
      rc=1
    fi
  else
    ok "Every configured app store uses https://"
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