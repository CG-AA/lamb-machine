#!/usr/bin/env bash
# Shared helpers for provision.sh: logging, dry-run execution, device guards,
# confirmation, layout iteration, and failure cleanup. Sourced, never run directly.

# --- logging -------------------------------------------------------------
if [[ -t 2 ]]; then
  C_RST=$'\e[0m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_DIM=$'\e[2m'
else
  C_RST=''; C_RED=''; C_YEL=''; C_BLU=''; C_DIM=''
fi
log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$@"; exit 1; }

# --- dry-run aware execution ---------------------------------------------
# DRY_RUN defaults to 1 (safe). provision.sh sets it to 0 only on `--yes`.
run() {
  if [[ "${DRY_RUN:-1}" == "1" ]]; then
    printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*" >&2
  else
    printf '  %s+%s %s\n' "$C_DIM" "$C_RST" "$*" >&2
    "$@"
  fi
}

# Write a file inside the target tree (creating parent dirs). Reads content from stdin.
write_target_file() {
  local path="$1" content; content="$(cat)"
  if [[ "${DRY_RUN:-1}" == "1" ]]; then
    printf '  %s[dry-run]%s would write %s:\n' "$C_DIM" "$C_RST" "$path" >&2
    local _line
    while IFS= read -r _line; do printf '        | %s\n' "$_line" >&2; done <<<"$content"
  else
    printf '  %s+%s write %s\n' "$C_DIM" "$C_RST" "$path" >&2
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" >"$path"
  fi
}

# --- environment checks --------------------------------------------------
require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}"
}

require_root() { [[ "$(id -u)" -eq 0 ]] || die "must run as root for a real run (use sudo)"; }

# True if $1 equals any later argument.
in_list() { local needle="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done; return 1; }

# --- device helpers ------------------------------------------------------
# Partition device name for a disk + index (nvme0n1 -> nvme0n1p1; sda -> sda1).
partdev() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then echo "${disk}p${num}"; else echo "${disk}${num}"; fi
}

# Refuse to touch a mounted disk or the disk hosting the running system.
assert_disk_safe() {
  local disk="$1"
  [[ -b "$disk" ]] || die "not a block device: $disk"
  if lsblk -nro MOUNTPOINT "$disk" 2>/dev/null | grep -q '[^[:space:]]'; then
    die "$disk has mounted partitions — refusing. Provision the real disk from a live USB."
  fi
  local root_src root_disk target_disk
  root_src="$(findmnt -nvo SOURCE / 2>/dev/null || true)"
  root_disk="$(lsblk -nso NAME "$root_src" 2>/dev/null | tail -1 || true)"
  target_disk="$(basename "$disk")"
  if [[ -n "$root_disk" && "$root_disk" == "$target_disk" ]]; then
    die "$disk hosts the running system (/) — refusing. Boot a live USB to provision it."
  fi
}

# Abort unless /dev/mapper/$1 exists and is backed by partition $2. Last line of
# defense against operating on the wrong (e.g. the running system's) mapper.
assert_mapper_backed_by() {
  local name="$1" want="$2" got
  got="$(lsblk -nspo NAME "/dev/mapper/$name" 2>/dev/null | sed -n '2p')"
  [[ -n "$want" && "$got" == "$want" ]] || \
    die "SAFETY: /dev/mapper/$name is backed by '${got:-<nothing>}', expected '${want:-<unset>}' — refusing."
}

# Refuse if a mapper named $LUKS_NAME already exists (it may be the running
# system's). Forces a unique LUKS_NAME or an explicit close before proceeding.
assert_mapper_free() {
  [[ -e "/dev/mapper/${LUKS_NAME:-}" ]] && \
    die "/dev/mapper/$LUKS_NAME already exists — refusing (it may be the running system's mapper). Close it, or set LUKS_NAME to a unique value."
  return 0
}

# Require the operator to type the device path (or supply CONFIRM_DEVICE for automation).
confirm_device() {
  local disk="$1" answer
  if [[ -n "${CONFIRM_DEVICE:-}" ]]; then
    answer="$CONFIRM_DEVICE"
  elif [[ -t 0 ]]; then
    read -rp "$(printf '%sType the target device to confirm DESTRUCTION (%s): %s' "$C_YEL" "$disk" "$C_RST")" answer
  else
    die "destructive run needs confirmation: set CONFIRM_DEVICE=$disk or run on a TTY"
  fi
  [[ "$answer" == "$disk" ]] || die "confirmation '$answer' does not match '$disk' — aborting"
}

# --- layout iteration ----------------------------------------------------
# Emit SUBVOLS rows sorted shallowest-mountpoint-first (so "/" mounts before /home etc.).
subvols_by_mount_depth() {
  local row mp depth
  for row in "${SUBVOLS[@]}"; do
    IFS='|' read -r _ mp _ _ <<<"$row"
    depth="$(tr -cd '/' <<<"${mp%/}" | wc -c)"
    printf '%d\t%s\n' "$depth" "$row"
  done | sort -n -k1,1 -s | cut -f2-
}

# --- failure cleanup -----------------------------------------------------
# Armed by provision.sh via `trap`. Unmounts the target tree and closes the LUKS
# mapper so a mid-run failure never leaves a half-formatted disk in a dirty state.
# Mounts are intentionally LEFT in place on success (the next step installs the OS).
cleanup_on_failure() {
  local rc=$?
  trap - ERR INT TERM
  warn "failure (exit $rc) — unwinding mounts/mapper to leave a clean state"
  if [[ -n "${TARGET:-}" ]] && mountpoint -q "$TARGET" 2>/dev/null; then
    umount -R "$TARGET" 2>/dev/null || warn "could not unmount $TARGET; do it manually"
  fi
  if [[ -n "${TOPMOUNT:-}" ]] && mountpoint -q "$TOPMOUNT" 2>/dev/null; then
    umount -R "$TOPMOUNT" 2>/dev/null || warn "could not unmount $TOPMOUNT; do it manually"
    rmdir "$TOPMOUNT" 2>/dev/null || true
  fi
  if [[ "${OPENED_LUKS:-0}" == "1" && -e "/dev/mapper/${LUKS_NAME:-}" ]]; then
    cryptsetup close "$LUKS_NAME" 2>/dev/null || warn "could not close $LUKS_NAME; do it manually"
  fi
  exit "$rc"
}
