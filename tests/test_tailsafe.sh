#!/usr/bin/env bash
# tests/test_tailsafe.sh - functional tests for the Tailscale-safety helpers
# added to linuxinstall.sh by tailsafe.patch.
#
# Usage:
#   bash tests/test_tailsafe.sh                  # test ../linuxinstall.sh
#   bash tests/test_tailsafe.sh /path/to/script # test a specific file
#
# Run from the repo root (tests/run-all.sh does this). The helpers are
# extracted with a python brace counter -- an awk range would stop at the first
# column-0 `}` inside the case/esac and yield a truncated, syntactically
# invalid function -- then sourced at top level with stubs so the whole file
# runs in one shell. Subshell isolation uses plain `( ... )` rather than
# `bash -c '...'`, keeping every construct in this file instead of a nested
# quoting layer.
#
# Follows the suite convention used by tests/run-all.sh: the final line is
# "All N test(s) passed." on success, which is what the harness parses for its
# pass count. Exits non-zero on any failure.

set -uo pipefail

SELF="${BASH_SOURCE[0]:-$0}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TARGET="${1:-$ROOT/linuxinstall.sh}"

pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# ── Extract a top-level function by brace counting ────────────────────────
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
  echo "       Apply tailsafe.patch first:  git apply tailsafe.patch"
  exit 1
fi
if ! extract_fn "$TARGET" _ts_ssh_is_access_path > /tmp/_ts_access.fn; then
  echo "FATAL: _ts_ssh_is_access_path not found in $TARGET"
  echo "       Apply tailsafe.patch first:  git apply tailsafe.patch"
  exit 1
fi

echo "=============================================================="
echo " tests/test_tailsafe.sh -- functional tests"
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
# `ok`/`bad` above are the result counters and must NOT be shadowed. The
# helpers only call `info`/`warn`/`err`, so those are stubbed as no-ops.
# (An earlier revision also stubbed `ok` here, which silently overrode the
# counter and made every result after the first report 0.)
FW_CMD=""
_fw_detect() { :; }          # leaves FW_CMD as the test set it
run() { printf '%s\n' "$*"; }
info() { :; }
warn() { :; }
err() { :; }

# ── Hermetic Tailscale stub ───────────────────────────────────────────────
# These tests must not depend on what happens to be installed on the machine
# running them. An earlier revision leaned on the host having a real
# /usr/bin/tailscale, which made the suite pass on a Tailscale node and fail on
# a clean CI runner: the helper correctly no-ops when Tailscale is absent, and
# the test read that correct no-op as a failure. The helper's guards are
# [ -x "$(command -v tailscale)" ], so satisfying them needs only an executable
# on PATH -- which is what this provides.
#
# Each condition is driven by a TS_* variable so a case can flip exactly one
# guard and leave the rest satisfied.
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/tailscale" <<'STUBEOF'
#!/bin/sh
case "$1" in
  status)
    printf '{"BackendState":"%s"}\n' "${TS_BACKEND:-Running}"
    ;;
  debug)
    printf '{"RunSSH":%s}\n' "${TS_RUNSSH:-true}"
    ;;
esac
exit 0
STUBEOF
chmod 0755 "$STUB_DIR/tailscale"
PATH="$STUB_DIR:$PATH"
hash -r

# systemctl is also consulted directly (is-active --quiet tailscaled), so a
# function stub is needed alongside the PATH stub.
systemctl() {
  case "${TS_DAEMON:-1}" in
    0) return 1 ;;
  esac
  return 0
}
_service_present() { [ "${TS_UNIT:-1}" = "1" ]; }

# shellcheck disable=SC1091
source /tmp/_ts_fw_allow.fn
# shellcheck disable=SC1091
source /tmp/_ts_access.fn

# Isolate the "tailscale present but not executable" case.
#
# Only A1 needs this. bash's PATH lookup *skips non-executable files*, so a
# 0644 stub does not shadow the real /usr/bin/tailscale -- `command -v` falls
# through to the real binary. To make the helper actually see the stub the
# PATH elements that provide a tailscale binary are dropped entirely.
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
    # Report what the helper's own guards will see, so the caller can tell a
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

# ── A2/A3/A4: drive FW_CMD directly ──────────────────────────────────────
# PATH manipulation is needed only for A1, to stop a 0644 stub being shadowed by
# a real binary. For these cases the STUB_DIR executable satisfies the helper's
# guards, so FW_CMD is driven directly and the assertions test the helper's
# logic rather than PATH-lookup corner cases.
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
  ok "A4 is a clean no-op when no active firewall is detected"
else
  bad "A4 emitted rules with no active firewall"
  echo "        got: $out"
fi
echo

# ── A5: happy path -- every condition satisfied -> access path confirmed ──
if _ts_ssh_is_access_path; then
  ok "A5 confirms the access path when all guards hold"
else
  bad "A5 failed to confirm the access path with all guards satisfied"
fi
echo

# ── A6: LINUXINSTALL_FORCE_SSHD=1 forces the OpenSSH path ────────────────
if LINUXINSTALL_FORCE_SSHD=1 _ts_ssh_is_access_path; then
  bad "A6 LINUXINSTALL_FORCE_SSHD=1 did not bypass the guard"
else
  ok "A6 LINUXINSTALL_FORCE_SSHD=1 forces the OpenSSH path"
fi
echo

# ── A7-A10: one guard broken at a time must each yield a refusal ──────────
# The guard gates whether openssh-server is installed, so a false positive
# reopens port 22 on a host the operator locked down. Each case flips exactly
# one condition and expects a refusal.
#
# shellcheck disable=SC2015
TS_BACKEND=NeedsLogin _ts_ssh_is_access_path \
  && bad "A7 backend != Running still reported the access path" \
  || ok "A7 refuses when the backend is not Running"

TS_RUNSSH=false _ts_ssh_is_access_path \
  && bad "A8 RunSSH=false still reported the access path" \
  || ok "A8 refuses when Tailscale SSH is disabled"

TS_DAEMON=0 _ts_ssh_is_access_path \
  && bad "A9 inactive tailscaled still reported the access path" \
  || ok "A9 refuses when tailscaled is not running"

TS_UNIT=0 _ts_ssh_is_access_path \
  && bad "A10 missing tailscaled unit still reported the access path" \
  || ok "A10 refuses when the tailscaled unit is absent"
echo

# ── A11: drop-zone rebind excludes tailscale0 (the hard-disconnect fix) ──
# Assert on the `grep -v` filter line itself rather than on "tailscale0"
# appearing anywhere near get-active-zones. A looser check also passes when
# only a comment mentions tailscale0, which is exactly the kind of vacuous
# assertion that survives a regression.
ln=$(grep -n 'get-active-zones' "$TARGET" | head -1 | cut -d: -f1)
filter=$(sed -n "${ln},$((ln + 4))p" "$TARGET" | grep 'grep -v' | head -1)
if printf '%s' "$filter" | grep -q 'tailscale0'; then
  ok "A11 drop-zone rebind excludes tailscale0 from the interface filter"
else
  bad "A11 drop-zone rebind still binds tailscale0 to drop"
  echo "        filter line: $filter"
fi
echo

# ── A12: _ts_fw_allow runs before fw_default_incoming_deny ────────────────
ts_line=$(grep -n '^  _ts_fw_allow$' "$TARGET" | head -1 | cut -d: -f1)
deny_line=$(grep -n '^  fw_default_incoming_deny$' "$TARGET" | head -1 | cut -d: -f1)
if [ -n "$ts_line" ] && [ -n "$deny_line" ] && [ "$ts_line" -lt "$deny_line" ]; then
  ok "A12 _ts_fw_allow ($ts_line) precedes fw_default_incoming_deny ($deny_line)"
else
  bad "A12 ordering wrong: ts=$ts_line deny=$deny_line"
fi
echo

# ── A13: access-path guard precedes the openssh-server install ────────────
guard_line=$(grep -n '^  if _ts_ssh_is_access_path; then$' "$TARGET" | head -1 | cut -d: -f1)
inst_line=$(grep -n '^  if ! command -v sshd >/dev/null 2>&1; then$' "$TARGET" | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$inst_line" ] && [ "$guard_line" -lt "$inst_line" ]; then
  ok "A13 access-path guard ($guard_line) precedes the sshd install ($inst_line)"
else
  bad "A13 ordering wrong: guard=$guard_line install=$inst_line"
fi
echo

rm -f /tmp/_ts_fw_allow.fn /tmp/_ts_access.fn
[ -n "${STUB_DIR:-}" ] && rm -rf "$STUB_DIR"

# tests/run-all.sh parses the pass count out of the final line, expecting
# "All N test(s) passed." Emitting that format here is what makes this suite's
# results visible in the aggregate summary rather than showing as 0 tests.
if [ "$fail" -eq 0 ]; then
  echo "All $pass test(s) passed."
  exit 0
fi

echo "$fail of $((pass + fail)) test(s) FAILED."
exit 1