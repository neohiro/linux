#!/usr/bin/env bash
# tests/test_color_fuzz.sh — property-based fuzz tests for the canonical
# color gate (lib/color-gate.sh via lib/color.sh).
#
# Invariants tested for every random configuration:
#   1. USE_COLOR ∈ {0, 1} (never undefined)
#   2. NEOHIRO_COLOR=0 forces gate closed
#   3. NEOHIRO_COLOR=1 forces gate open
#   4. TERM=dumb forces gate closed (unless NEOHIRO_COLOR=1)
#
# shellcheck source=../lib/color-gate.sh
# shellcheck source=../lib/color.sh
#
# Run: bash tests/test_color_fuzz.sh [N]   (default N=500)
set -u
PASS=0; FAIL=0
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_RST=$'\033[0m'
else C_RED=""; C_GRN=""; C_RST=""; fi
ok_t()   { printf '  %s[OK]  %s%s\n'   "$C_GRN" "$1" "$C_RST"; PASS=$((PASS+1)); }
fail_t() { printf '  %s[FAIL]%s %s\n    %s\n' "$C_RED" "$C_RST" "$1" "$2"; FAIL=$((FAIL+1)); }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_LIB="$ROOT/lib/color-gate.sh"
COLOR_LIB="$ROOT/lib/color.sh"
[ -f "$GATE_LIB" ] || { echo "lib/color-gate.sh not found"; exit 2; }
[ -f "$COLOR_LIB" ] || { echo "lib/color.sh not found"; exit 2; }

N="${1:-500}"
WD="$(mktemp -d)"
trap 'rm -rf "$WD"' EXIT

# The tput shim is recreated (and chmodded) on every iteration below;
# the version here serves as a valid default so the file exists before
# the first iteration's cat-overwrite.
cat > "$WD/tput" <<'TPUT'
#!/usr/bin/env bash
printf '%s\n' "${1:?}"
TPUT
chmod +x "$WD/tput"

# Sample "interesting" tput output values including pathological cases.
TPUT_VALUES=(
  "0"        # monochrome / broken terminfo
  "1"        # 1-color
  "7"        # 7-color (just below threshold)
  "8"        # exactly at threshold
  "16"
  "256"
  "16777216" # truecolor
  ""         # empty
  "-1"       # negative
  "garbage"  # non-numeric
  "0x10"     # hex (pathological)
  "8.5"      # float (pathological)
  "99999999999999999999" # overflow
  "  256  "  # whitespace padded
)

# Sample TERM values.
TERM_VALUES=(
  "" "xterm" "xterm-256color" "screen" "tmux-256color" "dumb" "linux" "vt100" "ansi"
)

# NO_COLOR values: empty, "0" (XDG: do not disable), "1" (disable),
# "true", "false", "yes", garbage.
NOCOLOR_VALUES=(
  "" "0" "1" "true" "false" "yes" "no" "garbage" "00" "01" "0001"
)

# NEOHIRO_COLOR values.
NEOCOLOR_VALUES=("" "0" "1" "garbage" "2" "-1")

# FORCE_TTY values.
FORCE_TTY_VALUES=("" "0" "1" "garbage")

random_choice() {
  local -a arr=("$@")
  echo "${arr[$((RANDOM % ${#arr[@]}))]}"
}

echo "Running $N fuzz iterations against $GATE_LIB"

for i in $(seq 1 "$N"); do
  TERM_CHOICE="$(random_choice "${TERM_VALUES[@]}")"
  NOCOLOR_CHOICE="$(random_choice "${NOCOLOR_VALUES[@]}")"
  NEOCOLOR_CHOICE="$(random_choice "${NEOCOLOR_VALUES[@]}")"
  FORCE_TTY_CHOICE="$(random_choice "${FORCE_TTY_VALUES[@]}")"
  TPUT_CHOICE="$(random_choice "${TPUT_VALUES[@]}")"

  # Run the gate in a clean subshell with the random config.
  out="$(
    # Keep system binaries accessible; prepend $WD so our tput shim wins.
    export PATH="$WD:/usr/bin:/bin"
    export TERM="$TERM_CHOICE"
    if [ -n "$NOCOLOR_CHOICE" ]; then export NO_COLOR="$NOCOLOR_CHOICE"; else unset NO_COLOR; fi
    if [ -n "$NEOCOLOR_CHOICE" ]; then export NEOHIRO_COLOR="$NEOCOLOR_CHOICE"; else unset NEOHIRO_COLOR; fi
    if [ -n "$FORCE_TTY_CHOICE" ]; then export FORCE_TTY="$FORCE_TTY_CHOICE"; else unset FORCE_TTY; fi
    cat > "$WD/tput" <<SHIM
#!/usr/bin/env bash
case "\$1" in
  colors) printf '%s\n' "$TPUT_CHOICE" ;;
  *)      printf '' ;;
esac
SHIM
    chmod +x "$WD/tput"
    # shellcheck disable=SC1090
    . "$GATE_LIB"
    uc=$(_apply_color_gate)
    printf 'UC=%s\n' "$uc"
  )"

  # Invariant 1: USE_COLOR must be 0 or 1
  uc="$(printf '%s' "$out" | sed -n 's/^UC=//p')"
  if [ "$uc" != "0" ] && [ "$uc" != "1" ]; then
    fail_t "iter $i: USE_COLOR out of range (got '$uc')" \
      "config: TERM=$TERM_CHOICE NO_COLOR=$NOCOLOR_CHOICE NEOHIRO_COLOR=$NEOCOLOR_CHOICE FORCE_TTY=$FORCE_TTY_CHOICE tput='$TPUT_CHOICE'"
    continue
  else
    PASS=$((PASS + 1))
  fi

  # Invariant 2: NEOHIRO_COLOR=0 forces closed
  if [ "$NEOCOLOR_CHOICE" = "0" ] && [ "$uc" = "1" ]; then
    fail_t "iter $i: NEOHIRO_COLOR=0 did not force gate closed" "got USE_COLOR=1"
    continue
  fi
  PASS=$((PASS + 1))

  # Invariant 3: NEOHIRO_COLOR=1 forces open
  if [ "$NEOCOLOR_CHOICE" = "1" ] && [ "$uc" = "0" ]; then
    fail_t "iter $i: NEOHIRO_COLOR=1 did not force gate open" "got USE_COLOR=0"
    continue
  fi
  PASS=$((PASS + 1))

  # Invariant 4: TERM=dumb forces closed (unless NEOHIRO_COLOR=1)
  if [ "$TERM_CHOICE" = "dumb" ] && [ "$NEOCOLOR_CHOICE" != "1" ] && [ "$uc" = "1" ]; then
    fail_t "iter $i: TERM=dumb did not force gate closed" "got USE_COLOR=1"
    continue
  fi
  PASS=$((PASS + 1))
done

echo
if [ "$FAIL" -eq 0 ]; then
  printf '%sAll %d fuzz iteration(s) passed (%d invariant checks).%s\n' \
    "$C_GRN" "$N" "$PASS" "$C_RST"; exit 0
else
  printf '%s%d of %d fuzz iterations failed.%s\n' \
    "$C_RED" "$FAIL" "$N" "$C_RST"; exit 1
fi