#!/usr/bin/env bash
#
# configure-test.sh — unit tests for configure.sh's PURE logic. No TTY, no root,
# no whiptail, no disk access. Sources configure.sh (its BASH_SOURCE guard keeps
# main() from running) and exercises the size/validation/render functions.
#
# Verifies:
#   1. size parsing + normalisation (IEC units, bare bytes, rejection)
#   2. capacity math + token/machine-name validators
#   3. WIZ_TEMPLATE does not drift from the reference layout.sh
#   4. render round-trip: the generated file re-sources into a valid SUBVOLS set,
#      DISK is hardcoded, OS_TAG stays env-overridable, and there are NO secrets
#   5. subvol toggling + resolved-name collision rejection (e.g. OS_TAG=space)
#
# Run:  ./configure-test.sh        (no privileges needed)
#
# This test deliberately (a) sets SEL_*/ENABLED globals that the sourced
# configure.sh functions read, and (b) passes single-quoted '$VAR' strings to
# field() which eval()s them in a clean subshell. Both trip shellcheck benignly.
# shellcheck disable=SC2034,SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the wizard for its functions; guard keeps main() from firing.
# shellcheck source=../configure.sh disable=SC1091
source "$HERE/../configure.sh"
set +e   # run every assertion; tally at the end

# Capture the reference layout BEFORE any build_resolved_subvols call clobbers it.
REF_SUBVOLS=("${SUBVOLS[@]}")

PASS=0; FAIL=0
phase() { printf '\n\033[34m### %s\033[0m\n' "$*"; }
ok()    { PASS=$((PASS + 1)); printf '\033[32m  PASS\033[0m %s\n' "$*"; }
bad()   { FAIL=$((FAIL + 1)); printf '\033[31m  FAIL\033[0m %s\n' "$*"; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }
want_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d (rc=$?)"; fi; }
want_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (expected non-zero)"; else ok "$d"; fi; }

# --- in a clean subshell, source the generated file and echo one expression ---
# shellcheck disable=SC1090
field() { ( unset OS_TAG LUKS_NAME DISK; source "$1"; eval "echo \"$2\"" ); }

phase "size parsing -> bytes"
eq  "1GiB"      1073741824 "$(parse_size_to_bytes 1GiB)"
eq  "1G"        1073741824 "$(parse_size_to_bytes 1G)"
eq  "1024MiB"   1073741824 "$(parse_size_to_bytes 1024MiB)"
eq  "512MiB"    536870912  "$(parse_size_to_bytes 512MiB)"
eq  "bare bytes" 1048576   "$(parse_size_to_bytes 1048576)"
eq  "lowercase 2t" 2199023255552 "$(parse_size_to_bytes 2t)"
want_fail "rejects garbage" parse_size_to_bytes garbage
want_fail "rejects zero"    parse_size_to_bytes 0
want_fail "rejects empty"   parse_size_to_bytes ""

phase "size normalisation -> sgdisk-safe IEC"
eq "1G   -> 1GiB"    1GiB    "$(normalize_size_iec 1G)"
eq "1GiB -> 1GiB"    1GiB    "$(normalize_size_iec 1GiB)"
eq "1024MiB kept"    1024MiB "$(normalize_size_iec 1024MiB)"
want_fail "bare number rejected (no unit -> sgdisk sectors footgun)" normalize_size_iec 123

phase "capacity math + validators"
eq "remaining = disk-esp-boot" 80 "$(capacity_remaining_bytes 100 10 10)"
want_ok   "valid_token main_ubt26"   valid_token main_ubt26
want_fail "valid_token rejects hyphen" valid_token bad-name
want_fail "valid_token rejects space"  valid_token "with space"
want_ok   "valid_machine oci-vm"      valid_machine oci-vm
want_fail "valid_machine rejects space" valid_machine "bad name"

phase "WIZ_TEMPLATE vs layout.sh (drift guard)"
SEL_TAG="$DEF_OS_TAG"; ENABLED=(_home _log _snapshots space archives)
build_resolved_subvols
drift=yes
if [[ "${#SUBVOLS[@]}" -ne "${#REF_SUBVOLS[@]}" ]]; then
  drift=no
else
  for i in "${!REF_SUBVOLS[@]}"; do [[ "${SUBVOLS[$i]}" == "${REF_SUBVOLS[$i]}" ]] || drift=no; done
fi
eq "rendered template == reference SUBVOLS" yes "$drift"
if [[ "$drift" == "no" ]]; then
  printf '   reference: %s\n' "${REF_SUBVOLS[@]}"
  printf '   rendered : %s\n' "${SUBVOLS[@]}"
fi

phase "render round-trip"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
SEL_DISK="/dev/sdX"; SEL_TAG="main_ubt26"; SEL_ESP="1GiB"; SEL_BOOT="1GiB"; SEL_LUKS="cryptroot"
ENABLED=(_home _log _snapshots space archives)
render_layout_file roundtrip >"$TMP"

eq "DISK hardcoded"        "/dev/sdX"   "$(field "$TMP" '$DISK')"
eq "OS_TAG default applies" "main_ubt26" "$(field "$TMP" '$OS_TAG')"
eq "LUKS_NAME default"      "cryptroot"  "$(field "$TMP" '$LUKS_NAME')"
eq "subvol count == 6"      6            "$(field "$TMP" '${#SUBVOLS[@]}')"
# every row has exactly 4 pipe-separated fields
eq "every row 4 fields" yes "$(field "$TMP" '$(s=yes; for r in "${SUBVOLS[@]}"; do IFS="|" read -ra f <<<"$r"; [ ${#f[@]} -eq 4 ] || s=no; done; printf %s "$s")')"
# exactly one root subvol (mountpoint "/")
eq "exactly one root row" 1 "$(field "$TMP" '$(c=0; for r in "${SUBVOLS[@]}"; do IFS="|" read -r n mp o p <<<"$r"; [ "$mp" = "/" ] && c=$((c+1)); done; printf %s "$c")')"
# env override re-tags the OS subvols from one knob
# shellcheck disable=SC1090
eq "OS_TAG override re-tags root" "@ubt28" \
   "$( ( unset LUKS_NAME DISK; export OS_TAG=ubt28; source "$TMP"; IFS='|' read -r n _ _ _ <<<"${SUBVOLS[0]}"; printf %s "$n" ) )"
# the file keeps the symbolic forms literal
want_ok "file keeps \${OS_TAG} literal"           grep -qF '@${OS_TAG}' "$TMP"
want_ok "file keeps \${DEFAULT_BTRFS_OPTS} literal" grep -qF '${DEFAULT_BTRFS_OPTS}' "$TMP"

phase "secrets boundary"
# The wizard must never write secret MATERIAL: the passphrase-bearing env var,
# a key-file reference, or PEM key data. (The header comment's reassuring use of
# the word "passphrase" is fine — we target the leak vectors, not the noun.)
if grep -qiE 'LUKS_PASSPHRASE|key-?file|PRIVATE KEY' "$TMP"; then
  bad "generated layout references secret material"
else
  ok "no secret material in generated layout"
fi

phase "subvol toggling + collision"
SEL_TAG="main_ubt26"; ENABLED=(_home _log _snapshots space)   # archives off
build_resolved_subvols
eq "disabling archives drops a row" 5 "${#SUBVOLS[@]}"
got_arch=no; for r in "${SUBVOLS[@]}"; do [[ "$r" == @archives\|* ]] && got_arch=yes; done
eq "@archives omitted when off" no "$got_arch"
# OS tag colliding with a fixed subvol name must be rejected
SEL_TAG="space"; ENABLED=(_home space)
want_fail "validate_subvols rejects OS_TAG=space (collides with @space)" validate_subvols
SEL_TAG="main_ubt26"; ENABLED=(_home _log _snapshots space archives)
want_ok   "validate_subvols accepts a clean set" validate_subvols

printf '\n'
if (( FAIL == 0 )); then
  printf '\033[32m### ALL %d CHECKS PASSED\033[0m\n' "$PASS"; exit 0
else
  printf '\033[31m### %d FAILED, %d passed\033[0m\n' "$FAIL" "$PASS"; exit 1
fi
