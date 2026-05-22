#!/usr/bin/env bash
# Declarative target disk layout, consumed by ./provision.sh.
# Bash-sourced — zero external dependencies (works on a bare Ubuntu live USB).
# Edit this file to retarget a machine. Defaults reproduce the reference machine
# documented in ./reference/this-machine.md.
#
# shellcheck disable=SC2034  # vars are consumed by provision.sh after sourcing

# --- disk ----------------------------------------------------------------
# Whole-disk device to provision. THIS DEVICE WILL BE WIPED by `fresh`.
# Overridable from the environment (e.g. for the loopback test).
DISK="${DISK:-/dev/nvme0n1}"

# Versioned prefix for the disposable OS subvolumes. Bump this per distro
# install (e.g. main_ubt28) so a new OS gets its own subvolumes while the
# shared ones below are kept. Overridable from the environment.
OS_TAG="${OS_TAG:-main_ubt26}"

# --- partitions ----------------------------------------------------------
# A `fresh` install creates a GPT with three contiguous partitions:
#   p1 ESP (vfat) -> /boot/efi   p2 /boot (ext4, unencrypted)   p3 LUKS (rest)
ESP_SIZE="1GiB"
BOOT_SIZE="1GiB"
# The LUKS partition takes the remainder of the disk.

# --- crypto --------------------------------------------------------------
# Name of the opened dm-crypt mapper (/dev/mapper/$LUKS_NAME). Overridable from
# the environment — the loopback test sets a unique name so it can never collide
# with a *running* system's "cryptroot" mapper.
LUKS_NAME="${LUKS_NAME:-cryptroot}"
# `fresh` formats with current cryptsetup LUKS2 defaults (strong, modern).
# Unlock is by interactive passphrase — no keyfile (crypttab: none).

# --- btrfs ---------------------------------------------------------------
DEFAULT_BTRFS_OPTS="noatime,compress=zstd:1,discard=async,space_cache=v2"

# Subvolume table — one row per subvolume:  name|mountpoint|mount_opts|persistence
#
#   persistence = recreate : wiped & remade on `reinstall` (OS-versioned, disposable)
#   persistence = preserve : never deleted; survives `reinstall` (shared data)
#
# Mountpoints are absolute paths inside the final system; provision.sh mounts
# them all under a temporary target root. The root subvol (mountpoint "/") may
# appear in any position — provision.sh always mounts shallowest paths first.
SUBVOLS=(
  "@${OS_TAG}|/|${DEFAULT_BTRFS_OPTS}|recreate"
  "@${OS_TAG}_home|/home|${DEFAULT_BTRFS_OPTS}|recreate"
  "@${OS_TAG}_log|/var/log|${DEFAULT_BTRFS_OPTS}|recreate"
  "@${OS_TAG}_snapshots|/.snapshots|${DEFAULT_BTRFS_OPTS}|recreate"
  "@space|/space|${DEFAULT_BTRFS_OPTS}|preserve"
  "@archives|/archives|noatime,compress=zstd:5,discard=async,space_cache=v2|preserve"
)
