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

# ── A12: EVERY _ts_fw_allow call precedes fw_default_incoming_deny ─────────
# Checks all call sites, not just the first. There are two by design: one for
# the already-active-firewall path and one for the fresh-install path after the
# firewall package is installed. Comparing only head -1 made this assertion
# vacuous the moment the second call site was added -- the early site is always
# before fw_default_incoming_deny, so the assertion passed even with the
# fresh-install ordering reverted. Mutation testing caught exactly that.
deny_line=$(grep -n '^  fw_default_incoming_deny$' "$TARGET" | head -1 | cut -d: -f1)
ts_all=$(grep -n '^  _ts_fw_allow$' "$TARGET" | cut -d: -f1 | tr '\n' ' ')
late=""
nsites=0
for l in $ts_all; do
  nsites=$((nsites + 1))
  [ "$l" -lt "$deny_line" ] || late="${late:+$late, }$l"
done
if [ "$nsites" -ge 1 ] && [ -n "$deny_line" ] && [ -z "$late" ]; then
  ok "A12 all $nsites _ts_fw_allow site(s) precede fw_default_incoming_deny ($deny_line)"
elif [ "$nsites" -lt 1 ]; then
  bad "A12 no _ts_fw_allow call site found"
else
  bad "A12 _ts_fw_allow at [$late] runs after fw_default_incoming_deny ($deny_line)"
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

# ── A14: _ts_fw_allow must precede setup_firewall's FIRST return ──────────
# Regression test. A12 only proved the call preceded fw_default_incoming_deny,
# which left the real hole open: setup_firewall returns early when a firewall
# is already active, and that early return happens *before* any
# fw_default_incoming_deny call. A single _ts_fw_allow placed at the old
# position was therefore dead code on every re-run against an already-hardened
# host -- which is the common case, and the case this fix exists to serve.
#
# Compared as relative offsets within the function body, so renumbering the
# file cannot break it.
setup_body=$(mktemp)
if extract_fn "$TARGET" setup_firewall > "$setup_body"; then
  # "^[[:space:]]+return" cannot match a comment: a comment line starts with #.
  first_allow=$(grep -nE '^[[:space:]]+_ts_fw_allow$' "$setup_body" | head -1 | cut -d: -f1)
  first_ret=$(grep -nE '^[[:space:]]+return([[:space:]]|$)' "$setup_body" | head -1 | cut -d: -f1)
  if [ -n "$first_allow" ] && [ -n "$first_ret" ] && [ "$first_allow" -lt "$first_ret" ]; then
    ok "A14 _ts_fw_allow (+$first_allow) precedes setup_firewall's first return (+$first_ret)"
  else
    bad "A14 _ts_fw_allow (${first_allow:-none}) does not precede first return (${first_ret:-none})"
    echo "        the already-active-firewall path returns before the rules are applied"
  fi
else
  bad "A14 could not extract setup_firewall"
fi
rm -f "$setup_body"
echo

# ── A15: restore_ssh_mode handles the no-sshd Tailscale case ──────────────
# harden_ssh() leaves Tailscale-SSH hosts with no sshd, but restore_ssh_mode
# used to treat that as a fault and tell the user to install openssh-server --
# advice that re-opens port 22 on exactly the host being recovered, and it
# returned 1 without repairing anything. It now branches on the same guard.
#
# Exercised behaviourally, not by grepping: both branches are driven and the
# messages and exit codes asserted. The no-sshd condition is not stubbed -- it
# is the real state of a Tailscale-only host, and the suite is expected to run
# where sshd is absent. `ok` is shadowed here because the helper under test
# calls the same name this suite uses for its own pass counter.
rsm_body=$(mktemp)
if extract_fn "$TARGET" restore_ssh_mode > "$rsm_body"; then
  _rsm_run() {   # $1 = value _ts_ssh_is_access_path should return
    (
      _RSM_GUARD_RC=$1
      ok()   { printf '%s\n' "$*"; }
      err()  { printf '%s\n' "$*"; }
      bold() { :; }
      # The guard is called with no arguments, so the return code has to arrive
      # via a variable rather than through $1.
      _ts_ssh_is_access_path() { return "$_RSM_GUARD_RC"; }
      # shellcheck disable=SC1090
      source "$rsm_body"
      restore_ssh_mode
      printf 'RC=%s\n' "$?"
    )
  }

  # Branch 1: Tailscale SSH IS the access path -> helpful, non-error, rc 0.
  out_ts=$(_rsm_run 0)
  if printf '%s' "$out_ts" | grep -q 'RC=0' \
     && ! printf '%s' "$out_ts" | grep -q 'pkg_install openssh-server' \
     && printf '%s' "$out_ts" | grep -qi 'tailscale'; then
    ok "A15 restore_ssh_mode explains the Tailscale-only state instead of erroring"
  else
    bad "A15 Tailscale-only branch is wrong"
    printf '%s\n' "$out_ts" | sed 's/^/        /'
  fi

  # Branch 2: no sshd AND no Tailscale SSH -> genuine fault, must say so, rc 1.
  out_none=$(_rsm_run 1)
  if printf '%s' "$out_none" | grep -q 'RC=1' \
     && printf '%s' "$out_none" | grep -q 'pkg_install openssh-server'; then
    ok "A15 restore_ssh_mode still reports a real fault when no access path exists"
  else
    bad "A15 no-access-path branch is wrong"
    printf '%s\n' "$out_none" | sed 's/^/        /'
  fi
else
  bad "A15 could not extract restore_ssh_mode"
fi
rm -f "$rsm_body"
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