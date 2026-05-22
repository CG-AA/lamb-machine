#!/usr/bin/env bash
#
# provision.sh — take a disk to a prepared LUKS2 + btrfs target per ./layout.sh.
#
#   fresh       wipe DISK and build the whole layout from scratch
#   reinstall   keep `preserve` subvols, recreate only `recreate` subvols (multi-distro)
#
#   partition|luks|mkfs|subvols|mount|gen-tab   run a single step (advanced)
#
# Default mode is --dry-run (prints exact commands). Add --yes to execute.
# Produces a *prepared, mounted target* — NOT a bootable system (see README.md).
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=layout.sh
source "${LAYOUT:-$HERE/layout.sh}"

# --- runtime state (also referenced by cleanup_on_failure) ---------------
DRY_RUN=1
TARGET="${TARGET:-/mnt/target}"
OPENED_LUKS=0
TOPMOUNT=""
LUKS_PART=""

usage() {
  sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'
}

# Partition holding the LUKS container on $1 (by filesystem type), if any.
find_luks_part() {
  lsblk -nrpo NAME,FSTYPE "$1" 2>/dev/null | awk '$2=="crypto_LUKS"{print $1; exit}'
}

# ========================================================================
# Steps
# ========================================================================

step_partition() {
  log "Partitioning $DISK — GPT: ESP $ESP_SIZE, /boot $BOOT_SIZE, LUKS (rest)"
  run wipefs -a "$DISK"
  run sgdisk --zap-all "$DISK"
  run sgdisk \
    -n1:0:+"$ESP_SIZE"  -t1:ef00 -c1:"EFI System" \
    -n2:0:+"$BOOT_SIZE" -t2:8300 -c2:"boot" \
    -n3:0:0             -t3:8309 -c3:"luks" \
    "$DISK"
  run partprobe "$DISK"
  run udevadm settle
}

step_luks_format() {
  LUKS_PART="$(partdev "$DISK" 3)"
  log "LUKS2 format on $LUKS_PART (cryptsetup defaults; no keyfile)"
  if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
    printf '%s' "$LUKS_PASSPHRASE" | run cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$LUKS_PART"
  else
    run cryptsetup luksFormat --type luks2 "$LUKS_PART"   # prompts for passphrase
  fi
  step_luks_open
}

step_luks_open() {
  : "${LUKS_PART:?LUKS_PART not set}"
  if [[ "$DRY_RUN" == "0" && -e "/dev/mapper/$LUKS_NAME" ]]; then
    log "/dev/mapper/$LUKS_NAME already open — reusing"
    return 0
  fi
  log "Opening $LUKS_PART as /dev/mapper/$LUKS_NAME"
  if [[ -n "${LUKS_PASSPHRASE:-}" ]]; then
    printf '%s' "$LUKS_PASSPHRASE" | run cryptsetup open --key-file=- "$LUKS_PART" "$LUKS_NAME"
  else
    run cryptsetup open "$LUKS_PART" "$LUKS_NAME"          # prompts for passphrase
  fi
  OPENED_LUKS=1
}

step_mkfs() {
  log "Creating filesystems (ESP vfat, /boot ext4, btrfs on $LUKS_NAME)"
  run mkfs.vfat -F32 "$(partdev "$DISK" 1)"
  run mkfs.ext4 -F "$(partdev "$DISK" 2)"
  run mkfs.btrfs -f "/dev/mapper/$LUKS_NAME"
}

# Verify, before any deletion, that recreating the OS subvols can't touch a
# `preserve` subvol, and that no unknown top-level subvols are lurking.
reinstall_preflight() {
  local top="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "  [dry-run] would inspect existing subvolumes and verify preserve-safety"
    return 0
  fi

  local existing=() s
  mapfile -t existing < <(btrfs subvolume list "$top" 2>/dev/null | sed -n 's/.* path //p')

  local recreate=() preserve=() known=() row name mp opts persist
  for row in "${SUBVOLS[@]}"; do
    IFS='|' read -r name mp opts persist <<<"$row"
    known+=("$name")
    [[ "$persist" == "recreate" ]] && recreate+=("$name")
    [[ "$persist" == "preserve" ]] && preserve+=("$name")
  done

  # (1) refuse on unexpected top-level subvolumes not described by the layout
  local unexpected=()
  for s in "${existing[@]}"; do
    [[ "$s" == */* ]] && continue
    in_list "$s" "${known[@]}" || unexpected+=("$s")
  done
  if ((${#unexpected[@]})) && [[ "${ALLOW_UNKNOWN_SUBVOLS:-0}" != "1" ]]; then
    err "unexpected top-level subvolumes not in layout.sh:"
    printf '      - %s\n' "${unexpected[@]}" >&2
    die "refusing. Add them to layout.sh (as preserve), remove them manually, or set ALLOW_UNKNOWN_SUBVOLS=1."
  fi

  # (2) compute the deletion set and prove no preserve subvol falls inside it
  local del=() t p
  for t in "${recreate[@]}"; do
    for s in "${existing[@]}"; do
      [[ "$s" == "$t" || "$s" == "$t/"* ]] && del+=("$s")
    done
  done
  for p in "${preserve[@]}"; do
    for s in "${del[@]:-}"; do
      [[ "$s" == "$p" || "$s" == "$p/"* ]] && \
        die "SAFETY: preserve subvol '$p' lies inside recreate target '$s' — aborting before any deletion."
    done
  done

  log "  preflight OK."
  if ((${#del[@]})); then
    log "  will delete (recreate targets + nested):"; printf '      - %s\n' "${del[@]}" >&2
  else
    log "  nothing to delete yet (no recreate targets present)."
  fi
  log "  will preserve: ${preserve[*]:-<none>}"
}

# Delete a recreate target and all its nested subvolumes, deepest-first.
delete_subvol_tree() {
  local top="$1" target="$2" s paths=()
  [[ -e "$top/$target" || "$DRY_RUN" == "1" ]] || { log "  $target absent — nothing to delete"; return 0; }
  if [[ "$DRY_RUN" == "0" ]]; then
    mapfile -t paths < <(
      btrfs subvolume list "$top" 2>/dev/null | sed -n 's/.* path //p' \
        | awk -v t="$target" '$0==t || index($0, t"/")==1' \
        | awk '{print gsub(/\//, "/") "\t" $0}' | sort -rn -k1,1 | cut -f2-
    )
  else
    paths=("$target")
  fi
  for s in "${paths[@]}"; do run btrfs subvolume delete "$top/$s"; done
}

step_create_subvols() {
  local mode="${1:-fresh}"
  local top; top="$(mktemp -d /tmp/lamb-top.XXXXXX)"
  TOPMOUNT="$top"
  log "Managing subvolumes (mode: $mode) via top-level mount at $top"
  run mount -o subvolid=5 "/dev/mapper/$LUKS_NAME" "$top"

  [[ "$mode" == "reinstall" ]] && reinstall_preflight "$top"

  local row name mp opts persist
  for row in "${SUBVOLS[@]}"; do
    IFS='|' read -r name mp opts persist <<<"$row"
    if [[ "$mode" == "reinstall" && "$persist" == "preserve" ]]; then
      log "  preserve: $name (left untouched)"
      continue
    fi
    [[ "$mode" == "reinstall" && "$persist" == "recreate" ]] && delete_subvol_tree "$top" "$name"
    run btrfs subvolume create "$top/$name"
  done

  run umount "$top"
  rmdir "$top" 2>/dev/null || true
  TOPMOUNT=""
}

step_mount() {
  log "Mounting subvolumes under $TARGET"
  run mkdir -p "$TARGET"
  local row name mp opts persist tgt
  while IFS= read -r row; do
    IFS='|' read -r name mp opts persist <<<"$row"
    tgt="$TARGET${mp%/}"            # mp="/" -> TARGET ; mp="/home" -> TARGET/home
    run mkdir -p "$tgt"
    run mount -o "subvol=$name,$opts" "/dev/mapper/$LUKS_NAME" "$tgt"
  done < <(subvols_by_mount_depth)

  run mkdir -p "$TARGET/boot"
  run mount "$(partdev "$DISK" 2)" "$TARGET/boot"
  run mkdir -p "$TARGET/boot/efi"
  run mount "$(partdev "$DISK" 1)" "$TARGET/boot/efi"
}

step_gen_tab() {
  [[ -n "$LUKS_PART" ]] || LUKS_PART="$(find_luks_part "$DISK" || true)"
  [[ -n "$LUKS_PART" ]] || LUKS_PART="$(partdev "$DISK" 3)"
  local btrfs_uuid luks_uuid esp_uuid boot_uuid
  if [[ "$DRY_RUN" == "0" ]]; then
    btrfs_uuid="$(blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")"
    luks_uuid="$(blkid -s UUID -o value "$LUKS_PART")"
    esp_uuid="$(blkid -s UUID -o value "$(partdev "$DISK" 1)")"
    boot_uuid="$(blkid -s UUID -o value "$(partdev "$DISK" 2)")"
  else
    btrfs_uuid="<btrfs-uuid>"; luks_uuid="<luks-part-uuid>"
    esp_uuid="<esp-uuid>"; boot_uuid="<boot-uuid>"
  fi

  log "Generating $TARGET/etc/fstab and crypttab"
  {
    echo "# /etc/fstab — generated by lamb-machine 00-provision"
    local row name mp opts persist
    while IFS= read -r row; do
      IFS='|' read -r name mp opts persist <<<"$row"
      printf 'UUID=%s\t%s\tbtrfs\tdefaults,%s,subvol=%s\t0 0\n' "$btrfs_uuid" "$mp" "$opts" "$name"
    done < <(subvols_by_mount_depth)
    printf 'UUID=%s\t/boot\text4\tdefaults\t0 1\n' "$boot_uuid"
    printf 'UUID=%s\t/boot/efi\tvfat\tdefaults\t0 1\n' "$esp_uuid"
  } | write_target_file "$TARGET/etc/fstab"

  {
    echo "# /etc/crypttab — generated by lamb-machine 00-provision"
    printf '%s\tUUID=%s\tnone\tluks,discard\n' "$LUKS_NAME" "$luks_uuid"
  } | write_target_file "$TARGET/etc/crypttab"
}

# ========================================================================
# Workflows
# ========================================================================

finish_ok() {
  trap - ERR INT TERM
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run complete — no changes made. Re-run with --yes to execute."
  else
    log "Done. Prepared target mounted at $TARGET."
    warn "NOT bootable yet: install the OS onto $TARGET, then a bootloader (see ../10-bootstrap)."
  fi
}

guard_destructive() {
  [[ "$DRY_RUN" == "0" ]] || return 0
  require_root
  assert_disk_safe "$DISK"
  confirm_device "$DISK"
}

do_fresh() {
  log "WORKFLOW fresh — wipe $DISK and build the full layout"
  guard_destructive
  step_partition
  step_luks_format
  step_mkfs
  step_create_subvols fresh
  step_mount
  step_gen_tab
  finish_ok
}

do_reinstall() {
  log "WORKFLOW reinstall — keep preserve subvols, recreate OS subvols on $DISK"
  if [[ "$DRY_RUN" == "0" ]]; then
    require_root
    assert_disk_safe "$DISK"
    LUKS_PART="$(find_luks_part "$DISK" || true)"
    [[ -n "$LUKS_PART" ]] || die "no crypto_LUKS partition found on $DISK"
    confirm_device "$DISK"
  else
    LUKS_PART="$(find_luks_part "$DISK" || true)"
    LUKS_PART="${LUKS_PART:-$(partdev "$DISK" 3)}"
  fi
  step_luks_open
  step_create_subvols reinstall
  step_mount
  step_gen_tab
  finish_ok
}

# ========================================================================
# Entry point
# ========================================================================

main() {
  local cmd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      fresh|reinstall|partition|luks|mkfs|subvols|mount|gen-tab) cmd="$1"; shift ;;
      --yes)      DRY_RUN=0; shift ;;
      --dry-run)  DRY_RUN=1; shift ;;
      -t|--target) TARGET="$2"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  [[ -n "$cmd" ]] || { usage; exit 1; }

  [[ "$DRY_RUN" == "0" ]] && require_cmds \
    sgdisk wipefs partprobe udevadm cryptsetup mkfs.vfat mkfs.ext4 mkfs.btrfs \
    btrfs mount umount lsblk blkid findmnt mountpoint

  trap cleanup_on_failure ERR INT TERM
  case "$cmd" in
    fresh)     do_fresh ;;
    reinstall) do_reinstall ;;
    partition) step_partition; finish_ok ;;
    luks)      step_luks_format; finish_ok ;;
    mkfs)      step_mkfs; finish_ok ;;
    subvols)   step_create_subvols fresh; finish_ok ;;
    mount)     step_mount; finish_ok ;;
    gen-tab)   step_gen_tab; finish_ok ;;
  esac
}

main "$@"
