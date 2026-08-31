#!/usr/bin/env bash
# tests/run-all.sh - Run every test suite and emit JUnit XML for CI.
#
# Usage:
#   bash tests/run-all.sh                  # run all, print summary, exit 0/non-zero
#   bash tests/run-all.sh --junit out.xml  # also write JUnit XML to out.xml
#   bash tests/run-all.sh --junit          # auto-name (test-results-YYYYMMDD-HHMMSS.xml)
#   bash tests/run-all.sh --verbose        # echo each suite's full output
set -u

SELF="${BASH_SOURCE[0]:-$0}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# --- Argument parsing ---
JUNIT_PATH=""
for arg in "$@"; do
  case "$arg" in
    --junit=*) JUNIT_PATH="${arg#--junit=}" ;;
    --junit)   JUNIT_PATH="auto" ;;
    --help|-h)
      # HELP_START / HELP_END markers make the range self-documenting.
      sed -n '/^# HELP_START$/,/^# HELP_END$/p' "$SELF" | sed 's/^# *//'
      exit 0
      ;;
    *) printf 'unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

if [ "$JUNIT_PATH" = "auto" ]; then
  JUNIT_PATH="$ROOT/test-results-$(date +%Y%m%d-%H%M%S).xml"
fi

# --- Suite definitions ---
# Each entry: "name|script|extra-args"
# Run both fast smoke (50 iter turbo) and full suite (200 iter).
# TURBO_MODE=1 reduces tput value space to 8 (from 14), further cutting time.
SUITES=(
  "color_gate|tests/test_color_gate.sh|"
  "curl_pipe_sim|tests/test_curl_pipe_sim.sh|"
  "fuzz_smoke|tests/test_color_fuzz.sh|50"
  "color_fuzz|tests/test_color_fuzz.sh|200"
  "linuxinstall|tests/test_linuxinstall.sh|"
  "updater|tests/test_updater.sh|"
  "verify_sync|verify_sync.sh|"
)

# Override for turbo smoke: run with NEOCOLOR_TURBO=1.
TURBO_SUITES="fuzz_smoke"

# --- Accumulators ---
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TIME=0
JUNIT_CASES=""          # accumulates one <testcase> XML element per suite.

# Escape four XML special chars: & < > and also " (used in attributes).
xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/\r//g'
}

# --- Run one suite, accumulate results ---
run_suite() {
  local name="$1" script="$2" extra="$3"
  local path="$ROOT/$script"
  if [ ! -f "$path" ]; then
    printf '  [SKIP] %-15s  (script not found: %s)\n' "$name" "$path" >&2
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    JUNIT_CASES="${JUNIT_CASES}
    <testcase classname=\"$name\" name=\"$name\" time=\"0\"><skipped/></testcase>"
    return
  fi

  local t0=$SECONDS exit_code full_out summary_line
  # If this suite is in the turbo list, set NEOCOLOR_TURBO=1.
  local extra_env=""
  for turbo_name in $TURBO_SUITES; do
    [ "$name" = "$turbo_name" ] && extra_env="NEOCOLOR_TURBO=1"
  done
  full_out="$(cd "$ROOT" && env $extra_env bash "$path" $extra 2>&1)"; exit_code=$?

  # Also capture just the last line for the summary column (printed below).
  # Use bash built-in rather than `tail` which may be missing on Windows.
  summary_line="$(printf '%s\n' "$full_out" | sed -n '$p')"

  local elapsed=$((SECONDS - t0))
  TOTAL_TIME=$((TOTAL_TIME + elapsed))

  # Extract pass count from the summary line.
  # Formats: "All N test(s) passed." or "All checks passed."
  local p=0
  local num_passed
  num_passed="$(printf '%s' "$summary_line" | grep -oE '^All[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | tail -1)"
  [ -n "$num_passed" ] && p="$num_passed"

  local escaped
  escaped="$(xml_escape "$full_out")"
  if [ "$exit_code" -eq 0 ]; then
    printf '  [PASS] %-15s %5d tests, %4ds\n' "$name" "$p" "$elapsed"
    TOTAL_PASS=$((TOTAL_PASS + p))
    JUNIT_CASES="${JUNIT_CASES}
    <testcase classname=\"$name\" name=\"$name\" time=\"${elapsed}\"><system-out>${escaped}</system-out></testcase>"
  else
    printf '  [FAIL] %-15s %5d tests, %4ds  (exit %d)\n' "$name" "$p" "$elapsed" "$exit_code"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    JUNIT_CASES="${JUNIT_CASES}
    <testcase classname=\"$name\" name=\"$name\" time=\"${elapsed}\"><failure message=\"exit ${exit_code}\">${escaped}</failure></testcase>"
  fi
}

# HELP_START
# tests/run-all.sh - Run every test suite and emit JUnit XML for CI.
#
# Options:
#   --junit[=path]   Write JUnit XML to path (auto-names if no path given)
#   --help, -h       Show this help text
#
# Exit code: 0 if all suites pass, 1 if any suite fails or is missing.
# JUnit XML is consumed by GitHub Actions, GitLab CI, Jenkins, etc.
# HELP_END

# --- Main ---
printf '=== tests/run-all.sh ===\n'
printf 'Running %d test suites...\n\n' "${#SUITES[@]}"
for entry in "${SUITES[@]}"; do
  IFS='|' read -r name script extra <<< "$entry"
  run_suite "$name" "$script" "$extra"
done

printf '\n=== Summary ===\n'
printf 'Total tests:    %d passed\n' "$TOTAL_PASS"
printf 'Suite failures: %d\n' "$TOTAL_FAIL"
printf 'Total runtime:  %ds\n' "$TOTAL_TIME"

if [ -n "$JUNIT_PATH" ]; then
  # Emit JUnit XML via a single group-redirected printf block.  This avoids
  # the > ... >> split pattern (a single-redirect group is more atomic and
  # leaves no partial file if the script is killed mid-write).
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites name="neohiro-linux" tests="%d" failures="%d" time="%ds">\n' \
      "${#SUITES[@]}" "$TOTAL_FAIL" "$TOTAL_TIME"
    printf '  <testsuite name="run-all" tests="%d" failures="%d" time="%ds">\n' \
      "${#SUITES[@]}" "$TOTAL_FAIL" "$TOTAL_TIME"
    printf '%s\n' "$JUNIT_CASES"
    printf '  </testsuite>\n'
    printf '</testsuites>\n'
  } > "$JUNIT_PATH"
  printf 'JUnit XML:      %s\n' "$JUNIT_PATH"
fi

[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
