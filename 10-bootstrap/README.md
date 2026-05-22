# 10-bootstrap (placeholder)

Post-provision OS setup. Assumes `00-provision` has prepared and mounted the target disk.

Planned contents (not built yet):
- Install Ubuntu onto the prepared mounts (debootstrap or installer handoff).
- Bootloader: GRUB with cryptodisk (unlocks LUKS root from the unencrypted `/boot`) + grub-btrfs
  for booting snapshots.
- `apt` manual-package list (~187 here) and `snap` list, regenerable + reinstallable.
- snapper configs (root / home / space) + snapper-rollback (see `/space/tool_scripts`).
- pyenv.
