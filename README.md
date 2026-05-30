# lamb-machine

The single source of truth for everything that personalizes my machines — built **from bare
metal up**, in layers. Each layer is independently runnable and documented.

```
00-provision/   disk → LUKS2 → btrfs subvolumes        (a prepared, mountable target)
10-bootstrap/   OS install, bootloader, packages, snapper, pyenv   (placeholder)
20-dotfiles/    shell, git, AI tools, editor — via chezmoi          (placeholder)
30-desktop/     GNOME settings + extensions                         (placeholder)

40-hermes-oci/  Hermes agent in a hardened rootless sandbox  (separate target: OCI ARM64 VM)
```

Lower layers are the foundation; higher layers assume the ones below exist. You can rebuild a
machine by walking up the stack. (`40-hermes-oci` is the exception — it targets a *different*
machine, a cloud VM, and assumes none of `00`–`30`; the number just sorts it last.)

## Why start at layer 0

The disk layout — an encrypted (LUKS2) btrfs filesystem with a deliberate **multi-distro
subvolume scheme** — is the part that's genuinely painful to reproduce by hand. The stock Ubuntu
installer has no "encrypted btrfs, dev layout" path. The defining idea:

- `@<os>*` subvolumes (e.g. `@main_ubt26`, `@main_ubt26_home`) are **OS-versioned and
  disposable** — wiped when you reinstall the distro.
- `@space` / `@archives` are **shared and persistent** — they survive an OS reinstall.

So you can nuke and reinstall the OS while your data subvolumes stay put. `00-provision` automates
exactly this. (Note: this very repo lives on `/space` = `@space`, so it survives the reinstalls it
performs.)

## Status

| Layer | State |
|-------|-------|
| `00-provision` | **implemented** — see [`00-provision/README.md`](00-provision/README.md) |
| `10-bootstrap` | placeholder |
| `20-dotfiles` | placeholder |
| `30-desktop` | placeholder |
| `40-hermes-oci` | **implemented** — *separate target: OCI ARM64 VM, not the workstation* — see [`40-hermes-oci/README.md`](40-hermes-oci/README.md) |

## Scope boundary (read this)

`00-provision` produces a **prepared target**: a partitioned, encrypted, btrfs-subvolume'd disk,
mounted with `fstab`/`crypttab` written — but **not a bootable system**. Installing the OS onto the
prepared mounts and the bootloader (GRUB cryptodisk + grub-btrfs) belong to `10-bootstrap` and are
not built yet.

## Conventions

- Layers are numbered so the order is obvious; lower numbers run first.
- No secrets in this repo — see `.gitignore`. Credentials, keys, and history files are excluded by
  design, even though the repo is currently local-only.
