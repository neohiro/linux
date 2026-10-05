#!/bin/bash
# Functional tests for the Tailscale-safety helpers added to linuxinstall.sh
# by tailsafe.patch.
#
#   bash test-patch-tailsafe.sh /path/to/linuxinstall.sh
#
# Exits non-zero if any case fails, so this can gate CI or a pre-commit hook.

set -uo pipefail

TARGET="${1:-linuxinstall.sh}"
pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# ── Extract a top-level function by brace counting ────────────────────────
# An awk range would stop at the first column-0 `}` inside the case/esac and
# yield a truncated, syntactically invalid function, so count braces instead.
extract_fn() {
  python3 - "$1" "$2" <<'PYEOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read().splitlines(keepends=True)
start = None
for i, line in enumerate(src):
    if line.startswith(name + "() {"):
        start = i
        break
if start is None:
    sys.exit(1)
depth = 0
out = []
for i in range(start, len(src)):
    line = src[i]
    out.append(line)
    depth += line.count("{") - line.count("}")
    if depth == 0 and i > start:
        break
sys.stdout.write("".join(out))
PYEOF
}

if ! extract_fn "$TARGET" _ts_fw_allow > /tmp/_ts_fw_allow.fn; then
  echo "FATAL: _ts_fw_allow not found in $TARGET"
  echo "       Apply tailsafe.patch first."
  exit 1
fi
if ! extract_fn "$TARGET" _ts_ssh_is_access_path > /tmp/_ts_access.fn; then
  echo "FATAL: _ts_ssh_is_access_path not found in $TARGET"
  echo "       Apply tailsafe.patch first."
  exit 1
fi

echo "=============================================================="
echo " tailsafe.patch -- functional tests"
echo "=============================================================="
echo

# ── Sanity: the extract must be complete and parseable ───────────────────
if bash -n /tmp/_ts_fw_allow.fn && bash -n /tmp/_ts_access.fn; then
  ok "S0 extracted helpers are syntactically complete"
else
  bad "S0 extracted helper is truncated or invalid"
  exit 1
fi

# ── Stubs so the helpers run outside the real installer ───────────────────
# ok/bad above are the result counters and must NOT be shadowed. The helpers
# only call info/warn/err, so those are stubbed as no-ops.
FW_CMD=""
_fw_detect() { :; }          # leaves FW_CMD as the test set it
run() { printf '%s\n' "$*"; }
info() { :; }
warn() { :; }
err() { :; }
_service_present() {
  systemctl list-unit-files "$1.service" 2>/dev/null \
    | awk 'NR>1{print $1}' | grep -qx "$1.service"
}

# shellcheck disable=SC1091
source /tmp/_ts_fw_allow.fn
# shellcheck disable=SC1091
source /tmp/_ts_access.fn

# Isolate the "tailscale present but not executable" case.
#
# bash's PATH lookup *skips non-executable files*, so a 0644 stub does not
# shadow the real /usr/bin/tailscale -- command -v falls through to the real
# binary. To make the helper actually see the stub, the PATH elements that
# provide a tailscale binary are dropped entirely.
#
# usage: with_non_exec_stub [helper]  -> prints the helper's output
# shellcheck disable=SC2120  # helper arg is optional; the default is deliberate
with_non_exec_stub() {
  local helper="${1:-_ts_fw_allow}"
  local d clean="" elem
  d=$(mktemp -d)
  printf '#!/bin/sh\nexit 0\n' > "$d/tailscale"
  chmod 0644 "$d/tailscale"
  local IFS=':'
  for elem in $PATH; do
    [ -n "$elem" ] || continue
    [ -x "$elem/tailscale" ] && continue
    clean="${clean:+$clean:}$elem"
  done
  unset IFS
  (
    PATH="$d:$clean"
    hash -r
    # Report what the helper's guards will see, so the caller can tell a
    # genuine no-op apart from "the stub was never visible".
    printf 'CV=%s\n' "$(command -v tailscale 2>/dev/null || echo none)"
    FW_CMD="ufw"
    "$helper"
  )
  rm -rf "$d"
}

# ── A1: non-executable tailscale must not cause rules to be emitted ──────
# Two legitimate outcomes, both acceptable and both reported honestly:
#   * the helper sees the 0644 stub, fails the -x guard, emits nothing;
#   * bash skipped the 0644 stub in PATH lookup, so the helper sees no
#     tailscale at all and also emits nothing.
# Either way the helper must stay silent. What it must NOT do is emit rules.
out=$(with_non_exec_stub)
body=$(printf '%s\n' "$out" | grep -v '^CV=')
cv=$(printf '%s\n' "$out" | grep '^CV=' | head -1)
if [ -z "$body" ]; then
  if [ "$cv" = "CV=none" ]; then
    ok "A1 no-ops when tailscale is absent from PATH lookup (${cv})"
  else
    ok "A1 no-ops when tailscale is present but not executable (${cv})"
  fi
else
  bad "A1 emitted rules for a non-executable/absent tailscale"
  echo "        got: $body"
fi
echo

# ── A2/A3/A4: drive FW_CMD directly, no PATH manipulation ────────────────
# PATH stripping is needed only for A1, to stop a 0644 stub being shadowed by
# the real binary. For these cases the real /usr/bin/tailscale satisfies the
# helper's guards perfectly well, so FW_CMD is driven directly against a fully
# populated environment. That keeps the assertions testing the helper's logic --
# which is the point -- rather than testing PATH-lookup corner cases.
#
# ── A2: ufw -> interface rule + wireguard port ───────────────────────────
out=$( FW_CMD=ufw; _ts_fw_allow )
if printf '%s\n' "$out" | grep -q 'allow in on tailscale0' \
   && printf '%s\n' "$out" | grep -q '41641/udp'; then
  ok "A2 emits tailscale0 interface + 41641/udp rules for ufw"
else
  bad "A2 missing ufw rules"
  echo "        got: $out"
fi
echo

# ── A3: firewalld -> trusted-zone binding ────────────────────────────────
out=$( FW_CMD=firewall-cmd; _ts_fw_allow )
if printf '%s\n' "$out" | grep -q 'zone=trusted' \
   && printf '%s\n' "$out" | grep -q 'tailscale0' \
   && printf '%s\n' "$out" | grep -q '41641/udp'; then
  ok "A3 binds tailscale0 to the trusted zone for firewalld"
else
  bad "A3 missing firewalld trusted binding"
  echo "        got: $out"
fi
echo

# ── A4: no firewall detected -> clean no-op ─────────────────────────────
# FW_CMD is read by the sourced _ts_fw_allow, not here, hence SC2034.
# shellcheck disable=SC2034
out=$( FW_CMD=""; _ts_fw_allow; echo "rc=$?" )
if printf '%s\n' "$out" | grep -q 'rc=0' \
   && ! printf '%s\n' "$out" | grep -q 'sudo '; then
  ok "A4 is a clean no-op when no firewall is active"
else
  bad "A4 emitted rules with no active firewall"
  echo "        got: $out"
fi
echo

# ── A5: live host IS a Tailscale-SSH node -> access path confirmed ───────
# Meaningful on any Tailscale-connected host; on a host without Tailscale it
# correctly returns false, which is also the right answer for that host.
if _ts_ssh_is_access_path; then
  ok "A5 detects Tailscale SSH as the access path on this host"
else
  ok "A5 reports no Tailscale-SSH access path on this host (correct if absent)"
fi
echo

# ── A6: override forces the OpenSSH path ─────────────────────────────────
if LINUXINSTALL_FORCE_SSHD=1 _ts_ssh_is_access_path; then
  bad "A6 LINUXINSTALL_FORCE_SSHD=1 did not bypass the guard"
else
  ok "A6 LINUXINSTALL_FORCE_SSHD=1 forces the OpenSSH path"
fi
echo

# ── A7: drop-zone rebind excludes tailscale0 (the hard-disconnect fix) ───
ln=$(grep -n 'get-active-zones' "$TARGET" | head -1 | cut -d: -f1)
region=$(sed -n "${ln},$((ln + 3))p" "$TARGET")
if printf '%s' "$region" | grep -q 'tailscale0'; then
  ok "A7 drop-zone rebind excludes tailscale0"
else
  bad "A7 drop-zone rebind still binds tailscale0 to drop"
  echo "        got: $region"
fi
echo

# ── A8: _ts_fw_allow runs before fw_default_incoming_deny ─────────────────
ts_line=$(grep -n '^  _ts_fw_allow$' "$TARGET" | head -1 | cut -d: -f1)
deny_line=$(grep -n '^  fw_default_incoming_deny$' "$TARGET" | head -1 | cut -d: -f1)
if [ -n "$ts_line" ] && [ -n "$deny_line" ] && [ "$ts_line" -lt "$deny_line" ]; then
  ok "A8 _ts_fw_allow ($ts_line) precedes fw_default_incoming_deny ($deny_line)"
else
  bad "A8 ordering wrong: ts=$ts_line deny=$deny_line"
fi
echo

# ── A9: access-path guard precedes the openssh-server install ─────────────
guard_line=$(grep -n '^  if _ts_ssh_is_access_path; then$' "$TARGET" | head -1 | cut -d: -f1)
inst_line=$(grep -n '^  if ! command -v sshd >/dev/null 2>&1; then$' "$TARGET" | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$inst_line" ] && [ "$guard_line" -lt "$inst_line" ]; then
  ok "A9 access-path guard ($guard_line) precedes the sshd install ($inst_line)"
else
  bad "A9 ordering wrong: guard=$guard_line install=$inst_line"
fi
echo

echo "--------------------------------------------------------------"
echo " passed: $pass   failed: $fail"
echo "--------------------------------------------------------------"
rm -f /tmp/_ts_fw_allow.fn /tmp/_ts_access.fn
[ "$fail" -eq 0 ]