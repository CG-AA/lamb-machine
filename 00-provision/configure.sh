#!/usr/bin/env bash
#
# configure.sh — interactive wizard that GENERATES a per-machine disk layout.
#
# Walks: select disk -> partition sizes -> OS tag -> LUKS name -> subvolumes ->
# machine name -> review, then writes a tracked `layout.<machine>.sh` that the
# existing ./provision.sh consumes via LAYOUT=. It is a *generator only*:
#   - performs NO destructive disk operations (all disk access is read-only),
#   - never calls provision.sh and never touches the engine,
#   - never writes the LUKS passphrase (that stays runtime-only).
# When done it prints the exact provision.sh command to run.
#
# Front-end: whiptail (ships on Ubuntu live via `newt`). Linear flow; Cancel/Esc
# at any step aborts the whole wizard after a confirm. A step only re-prompts
# itself on invalid input. See ./README.md and the sibling provision.sh.
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=layout.sh
source "${LAYOUT:-$HERE/layout.sh}"   # for template defaults (opts, sizes, tag, luks name)

# Capture the reference defaults, then drop the sourced DISK so it can never
# preselect a real device (layout.sh defaults it to /dev/nvme0n1).
DEF_OS_TAG="${OS_TAG:-main_ubt26}"
DEF_LUKS="${LUKS_NAME:-cryptroot}"
DEF_ESP="${ESP_SIZE:-1GiB}"
DEF_BOOT="${BOOT_SIZE:-1GiB}"
DEF_OPTS="${DEFAULT_BTRFS_OPTS:-noatime,compress=zstd:1,discard=async,space_cache=v2}"
unset DISK

BACKTITLE="lamb-machine • 00-provision • layout wizard"

# Subvolume template — one row per subvolume the wizard can emit:
#   kind|token|mountpoint|optskind|persistence
#     kind     = root  -> always present, mounted at / , name @${OS_TAG}
#                os    -> optional, name @${OS_TAG}<token>   (token incl. leading _)
#                fixed -> optional, name @<token>            (shared/persistent data)
#     optskind = default        -> rendered as ${DEFAULT_BTRFS_OPTS}
#                literal:<opts>  -> rendered verbatim
# Kept deliberately parallel to layout.sh's SUBVOLS; configure-test.sh asserts
# it does not drift from the reference layout.
WIZ_TEMPLATE=(
  "root|root|/|default|recreate"
  "os|_home|/home|default|recreate"
  "os|_log|/var/log|default|recreate"
  "os|_snapshots|/.snapshots|default|recreate"
  "fixed|space|/space|default|preserve"
  "fixed|archives|/archives|literal:noatime,compress=zstd:5,discard=async,space_cache=v2|preserve"
)

# --- wizard selections (filled in as we go) ------------------------------
SEL_DISK=""; SEL_DISK_BYTES=0
SEL_ESP="$DEF_ESP"; SEL_BOOT="$DEF_BOOT"; SEL_REM_BYTES=0
SEL_TAG="$DEF_OS_TAG"; SEL_LUKS="$DEF_LUKS"
SEL_MACHINE=""; OUT_FILE=""
ENABLED=()            # enabled optional tokens (from the subvol checklist)
WT_RESULT=""          # last whiptail value
VALIDATION_MSG=""

# ========================================================================
# Pure logic (no whiptail I/O — unit-tested by test/configure-test.sh)
# ========================================================================

# Parse an IEC size to bytes. Accepts 1G / 1GiB / 1024MiB / bare bytes (1048576).
# Echoes the byte count; returns 1 on malformed or zero input.
parse_size_to_bytes() {
  local s="${1//[[:space:]]/}" num unit mult
  [[ "$s" =~ ^([0-9]+)([KkMmGgTt]?)[iI]?[bB]?$ ]] || return 1
  num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]^^}"
  case "$unit" in
    "") mult=1 ;;
    K)  mult=1024 ;;
    M)  mult=$((1024 ** 2)) ;;
    G)  mult=$((1024 ** 3)) ;;
    T)  mult=$((1024 ** 4)) ;;
  esac
  (( num > 0 )) || return 1
  echo $(( num * mult ))
}

# Normalise a size to a canonical, sgdisk-valid IEC form (e.g. 1G -> 1GiB).
# REQUIRES an explicit unit (a bare byte count would mean *sectors* to sgdisk,
# which is a footgun) — returns 1 if no unit is given.
normalize_size_iec() {
  local s="${1//[[:space:]]/}" num unit
  [[ "$s" =~ ^([0-9]+)([KkMmGgTt])[iI]?[bB]?$ ]] || return 1
  num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]^^}"
  (( num > 0 )) || return 1
  printf '%s%siB' "$num" "$unit"
}

# Bytes -> a friendly "474.9 GiB" for display only.
human_bytes() {
  awk -v b="$1" 'BEGIN{
    split("B KiB MiB GiB TiB PiB", u, " "); i=1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

disk_bytes() { lsblk -bdno SIZE "$1" 2>/dev/null; }

# Bytes left for the LUKS partition after the ESP and /boot are carved out.
capacity_remaining_bytes() { echo $(( $1 - $2 - $3 )); }

valid_token()   { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }       # OS tag / LUKS mapper name
valid_machine() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }       # machine label -> filename

# --- read-only disk predicates (re-promptable; mirror assert_disk_safe) ---
# True when $1 is the whole-disk device that backs the running system's root.
# Replicates lib/common.sh:assert_disk_safe's detection (incl. the load-bearing
# raw `-r` flag) but returns a status instead of die()-ing, so the wizard can
# simply skip the disk in the list rather than abort.
disk_hosts_running_system() {
  local disk="$1" root_src root_disk
  root_src="$(findmnt -nvo SOURCE / 2>/dev/null || true)"
  [[ -n "$root_src" ]] || return 1
  root_disk="$(lsblk -nsro NAME "$root_src" 2>/dev/null | tail -1 || true)"
  [[ -n "$root_disk" && "$(basename "$disk")" == "$root_disk" ]]
}
disk_has_mounts() { lsblk -nro MOUNTPOINT "$1" 2>/dev/null | grep -q '[^[:space:]]'; }
disk_has_partitions() { (( "$(lsblk -nro NAME "$1" 2>/dev/null | wc -l)" > 1 )); }
disk_has_luks() {
  lsblk -nrpo NAME,FSTYPE "$1" 2>/dev/null | awk '$2=="crypto_LUKS"{f=1} END{exit !f}'
}
mapper_exists() { [[ -e "/dev/mapper/$1" ]]; }

# --- subvolume assembly + rendering --------------------------------------
# Symbolic (for the generated file — keeps ${OS_TAG}/${DEFAULT_BTRFS_OPTS} literal
# so a later `OS_TAG=… provision.sh reinstall` re-tags from one knob).
# shellcheck disable=SC2016  # ${OS_TAG} is emitted LITERALLY into the generated file
symbolic_name() {
  case "$1" in
    root)  printf '@${OS_TAG}' ;;
    os)    printf '@${OS_TAG}%s' "$2" ;;
    fixed) printf '@%s' "$2" ;;
  esac
}
# shellcheck disable=SC2016  # ${DEFAULT_BTRFS_OPTS} is emitted LITERALLY
symbolic_opts() {
  case "$1" in
    default)   printf '${DEFAULT_BTRFS_OPTS}' ;;
    literal:*) printf '%s' "${1#literal:}" ;;
  esac
}
# Resolved (chosen tag / real opts substituted) — for validation and the review.
resolve_name() {
  case "$1" in
    root)  printf '@%s'   "$SEL_TAG" ;;
    os)    printf '@%s%s' "$SEL_TAG" "$2" ;;
    fixed) printf '@%s'   "$2" ;;
  esac
}
resolve_opts() {
  case "$1" in
    default)   printf '%s' "$DEF_OPTS" ;;
    literal:*) printf '%s' "${1#literal:}" ;;
  esac
}

# Is a template row enabled? Root always is; optional rows depend on the checklist.
is_enabled() {
  [[ "$1" == "root" ]] && return 0
  in_list "$2" "${ENABLED[@]:-}"
}

# Validate the chosen subvol set on RESOLVED names: every name well-formed and
# unique (an OS tag colliding with a fixed subvol, e.g. tag=space -> @space, is
# rejected here). Sets VALIDATION_MSG and returns 1 on failure.
validate_subvols() {
  local spec kind token mp optskind persist name names=()
  for spec in "${WIZ_TEMPLATE[@]}"; do
    IFS='|' read -r kind token mp optskind persist <<<"$spec"
    is_enabled "$kind" "$token" || continue
    name="$(resolve_name "$kind" "$token")"
    [[ "$name" =~ ^@[A-Za-z0-9_]+$ ]] || { VALIDATION_MSG="Invalid subvolume name '$name'."; return 1; }
    if in_list "$name" "${names[@]:-}"; then
      VALIDATION_MSG="Duplicate subvolume name '$name' — the OS tag '$SEL_TAG' collides with a fixed subvolume. Pick a different tag."
      return 1
    fi
    names+=("$name")
  done
  return 0
}

# Populate the global SUBVOLS with the resolved, enabled rows (so the reused
# subvols_by_mount_depth from common.sh can order them for the review screen).
build_resolved_subvols() {
  SUBVOLS=()
  local spec kind token mp optskind persist
  for spec in "${WIZ_TEMPLATE[@]}"; do
    IFS='|' read -r kind token mp optskind persist <<<"$spec"
    is_enabled "$kind" "$token" || continue
    SUBVOLS+=("$(resolve_name "$kind" "$token")|$mp|$(resolve_opts "$optskind")|$persist")
  done
}

# Emit the full layout.<machine>.sh text to stdout. DISK is hardcoded to the
# validated choice; OS_TAG/LUKS_NAME stay env-overridable; sizes are resolved.
# shellcheck disable=SC2016  # ${OS_TAG}/${LUKS_NAME} are emitted LITERALLY (env-overridable in the file)
render_layout_file() {
  local machine="$1" today spec kind token mp optskind persist
  today="$(date -u +%Y-%m-%d 2>/dev/null || echo unknown)"
  printf '#!/usr/bin/env bash\n'
  printf "# GENERATED by configure.sh for machine '%s' on %s — tracked, committed layout.\n" "$machine" "$today"
  printf '# Consumed by ./provision.sh via LAYOUT=. Regenerate any time with ./configure.sh.\n'
  printf '# Contains NO secrets (the LUKS passphrase is entered interactively at provision time).\n'
  printf '# shellcheck disable=SC2034\n\n'
  printf 'DISK="%s"\n' "$SEL_DISK"
  printf 'OS_TAG="${OS_TAG:-%s}"\n\n' "$SEL_TAG"
  printf 'ESP_SIZE="%s"\n' "$SEL_ESP"
  printf 'BOOT_SIZE="%s"\n\n' "$SEL_BOOT"
  printf 'LUKS_NAME="${LUKS_NAME:-%s}"\n\n' "$SEL_LUKS"
  printf 'DEFAULT_BTRFS_OPTS="%s"\n\n' "$DEF_OPTS"
  printf 'SUBVOLS=(\n'
  for spec in "${WIZ_TEMPLATE[@]}"; do
    IFS='|' read -r kind token mp optskind persist <<<"$spec"
    is_enabled "$kind" "$token" || continue
    printf '  "%s|%s|%s|%s"\n' "$(symbolic_name "$kind" "$token")" "$mp" "$(symbolic_opts "$optskind")" "$persist"
  done
  printf ')\n'
}

# ========================================================================
# whiptail I/O (thin) — Cancel/Esc funnel to a single confirm-quit
# ========================================================================

# Run whiptail, capture its selection into WT_RESULT, return its exit status
# (0 ok, 1 cancel, 255 esc). UI is drawn on fd2 (the tty) so stdout stays clean.
_wt() { WT_RESULT="$(whiptail --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3)"; }
wt_msgbox() { whiptail --backtitle "$BACKTITLE" --title "${2:-Notice}" --msgbox "$1" "${3:-12}" "${4:-72}" 3>&1 1>&2 2>&3 || true; }
wt_yesno()  { whiptail --backtitle "$BACKTITLE" --title "${2:-Confirm}" --yesno  "$1" "${3:-10}" "${4:-66}" 3>&1 1>&2 2>&3; }

# Called whenever a step is cancelled/esc'd. Quits the wizard (nothing written)
# if confirmed; otherwise returns so the caller re-shows the current step.
confirm_abort() {
  if wt_yesno "Quit the wizard without writing a layout?" "Quit?" 8 64; then
    log "aborted — no layout written"; exit 1
  fi
}

# ========================================================================
# Steps (each loops until it has a valid value)
# ========================================================================

step_select_disk() {
  local name size type model dev args=() first="on" n=0
  while read -r name size type model; do
    [[ "$type" == "disk" ]] || continue
    dev="/dev/$name"
    disk_hosts_running_system "$dev" && continue
    disk_has_mounts "$dev" && continue
    args+=("$dev" "$size  ${model:-disk}" "$first"); first="off"; n=$((n + 1))
  done < <(lsblk -dno NAME,SIZE,TYPE,MODEL)

  if (( n == 0 )); then
    wt_msgbox "No eligible target disk found.\n\nEvery disk is mounted or hosts the running system. Provision the real disk from a live USB." "No disks"
    exit 1
  fi

  while true; do
    _wt --title "Select target disk" \
        --radiolist "Disk to provision — it will be WIPED by 'fresh'.\n(Space selects, Tab to OK.)" \
        18 72 "$n" "${args[@]}" || { confirm_abort; continue; }
    [[ -n "$WT_RESULT" ]] || { wt_msgbox "Pick a disk with Space, then OK."; continue; }
    SEL_DISK="$WT_RESULT"
    if disk_has_luks "$SEL_DISK" || disk_has_partitions "$SEL_DISK"; then
      wt_yesno "$SEL_DISK already has partitions or a LUKS container.\n\n'fresh' will DESTROY everything on it. Continue with this disk?" \
               "Disk not empty" 12 70 || { SEL_DISK=""; continue; }
    fi
    SEL_DISK_BYTES="$(disk_bytes "$SEL_DISK")" || true
    [[ -n "$SEL_DISK_BYTES" ]] || { wt_msgbox "Could not read the size of $SEL_DISK."; SEL_DISK=""; continue; }
    return 0
  done
}

step_sizes() {
  local esp boot esp_b boot_b rem
  while true; do
    _wt --title "ESP size" --inputbox "EFI System Partition size (vfat, /boot/efi).\nInclude a unit, e.g. 1GiB or 512MiB:" 10 66 "$DEF_ESP" \
      || { confirm_abort; continue; }
    esp="$(normalize_size_iec "$WT_RESULT")" || { wt_msgbox "Invalid size '$WT_RESULT'. Include a unit, e.g. 1GiB."; continue; }

    _wt --title "/boot size" --inputbox "Unencrypted /boot partition size (ext4).\nInclude a unit, e.g. 1GiB:" 10 66 "$DEF_BOOT" \
      || { confirm_abort; continue; }
    boot="$(normalize_size_iec "$WT_RESULT")" || { wt_msgbox "Invalid size '$WT_RESULT'. Include a unit, e.g. 1GiB."; continue; }

    esp_b="$(parse_size_to_bytes "$esp")"; boot_b="$(parse_size_to_bytes "$boot")"
    rem="$(capacity_remaining_bytes "$SEL_DISK_BYTES" "$esp_b" "$boot_b")"
    if (( rem <= 0 )); then
      wt_msgbox "ESP ($esp) + /boot ($boot) do not fit on $SEL_DISK ($(human_bytes "$SEL_DISK_BYTES")).\nChoose smaller sizes."; continue
    fi
    wt_yesno "ESP:          $esp\n/boot:        $boot\nLUKS (rest):  $(human_bytes "$rem")\n\nProceed with these sizes?" "Confirm sizes" 12 66 \
      || continue
    SEL_ESP="$esp"; SEL_BOOT="$boot"; SEL_REM_BYTES="$rem"; return 0
  done
}

step_os_tag() {
  while true; do
    _wt --title "OS tag" --inputbox "Versioned prefix for the disposable OS subvolumes\n(bump per distro install, e.g. main_ubt28):" 10 66 "$DEF_OS_TAG" \
      || { confirm_abort; continue; }
    valid_token "$WT_RESULT" || { wt_msgbox "Invalid tag '$WT_RESULT' — letters, digits and _ only."; continue; }
    SEL_TAG="$WT_RESULT"; return 0
  done
}

step_luks_name() {
  while true; do
    _wt --title "LUKS mapper name" --inputbox "dm-crypt mapper name (/dev/mapper/<name>).\nMust be unique vs. any running system's mapper:" 10 66 "$DEF_LUKS" \
      || { confirm_abort; continue; }
    valid_token "$WT_RESULT" || { wt_msgbox "Invalid name '$WT_RESULT' — letters, digits and _ only."; continue; }
    SEL_LUKS="$WT_RESULT"
    mapper_exists "$SEL_LUKS" && wt_msgbox "Heads up: /dev/mapper/$SEL_LUKS already exists right now.\nThe real run will refuse it unless it is closed or renamed." "Mapper in use"
    return 0
  done
}

step_subvols() {
  local spec kind token mp optskind persist args=() t
  for spec in "${WIZ_TEMPLATE[@]}"; do
    IFS='|' read -r kind token mp optskind persist <<<"$spec"
    [[ "$kind" == "root" ]] && continue        # root is mandatory, not toggleable
    args+=("$token" "$mp  ($persist)" "on")
  done
  while true; do
    _wt --separate-output --title "Subvolumes" \
        --checklist "Optional subvolumes to create (root / is always made).\nSpace toggles, Tab to OK:" \
        15 72 5 "${args[@]}" || { confirm_abort; continue; }
    ENABLED=()
    while IFS= read -r t; do [[ -n "$t" ]] && ENABLED+=("$t"); done <<<"$WT_RESULT"
    if validate_subvols; then return 0; fi
    wt_msgbox "$VALIDATION_MSG"
  done
}

step_machine_name() {
  local def; def="$(hostname -s 2>/dev/null || true)"; [[ -n "$def" ]] || def="machine"
  while true; do
    _wt --title "Machine name" --inputbox "Name for THIS target machine — becomes layout.<name>.sh.\nOn a live USB the default is the live env's name; type the target's:" 11 72 "$def" \
      || { confirm_abort; continue; }
    valid_machine "$WT_RESULT" || { wt_msgbox "Invalid name '$WT_RESULT' — letters, digits, _ and - only."; continue; }
    SEL_MACHINE="$WT_RESULT"; OUT_FILE="$HERE/layout.$SEL_MACHINE.sh"
    if [[ -e "$OUT_FILE" ]]; then
      wt_yesno "00-provision/layout.$SEL_MACHINE.sh already exists.\n\nOverwrite it?" "Overwrite?" 10 66 || continue
    fi
    return 0
  done
}

step_review() {
  build_resolved_subvols
  local row name mp persist table=""
  while IFS= read -r row; do
    IFS='|' read -r name mp _ persist <<<"$row"
    table+="$(printf '  %-12s %-20s %s' "$mp" "$name" "$persist")"$'\n'
  done < <(subvols_by_mount_depth)

  local body
  body="Target disk : $SEL_DISK  ($(human_bytes "$SEL_DISK_BYTES"))
              ^ WILL BE WIPED by 'fresh'

ESP         : $SEL_ESP
/boot       : $SEL_BOOT
LUKS (rest) : $(human_bytes "$SEL_REM_BYTES")
OS tag      : $SEL_TAG
LUKS mapper : $SEL_LUKS

Subvolumes (mount order):
$table
Output      : 00-provision/layout.$SEL_MACHINE.sh  (tracked)"

  while true; do
    wt_yesno "$body\n\nWrite this layout? (nothing has been written yet)" "Review" 24 76 && return 0
    confirm_abort
  done
}

write_layout() {
  render_layout_file "$SEL_MACHINE" >"$OUT_FILE"
  log "wrote $OUT_FILE"
  local rel="layout.$SEL_MACHINE.sh"
  wt_msgbox "Wrote 00-provision/$rel\n\nNext (from the 00-provision directory):\n\n  sudo LAYOUT=$rel ./provision.sh fresh --dry-run\n  sudo LAYOUT=$rel ./provision.sh fresh --yes\n\nThe file is tracked — commit it to record this machine." "Done" 16 74
  cat >&2 <<EOF

${C_BLU}[*]${C_RST} Layout written: 00-provision/$rel  (tracked — commit it)

  Review the plan (dry-run, changes nothing):
    cd 00-provision && sudo LAYOUT=$rel ./provision.sh fresh --dry-run

  Execute when satisfied (prompts for the LUKS passphrase):
    cd 00-provision && sudo LAYOUT=$rel ./provision.sh fresh --yes
EOF
}

# ========================================================================
# Entry point
# ========================================================================
main() {
  command -v whiptail >/dev/null 2>&1 || die "whiptail not found — install it:  sudo apt-get install -y whiptail"
  [[ -t 0 && -t 2 ]] || die "configure.sh is interactive — run it directly in a terminal."
  step_select_disk
  step_sizes
  step_os_tag
  step_luks_name
  step_subvols
  step_machine_name
  step_review
  write_layout
}

# Sourceable for unit tests (test/configure-test.sh); only run when executed.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
