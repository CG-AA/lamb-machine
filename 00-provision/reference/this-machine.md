# Reference: this machine's disk layout

Captured 2026-05-23 as the ground truth that `layout.sh` reproduces. This is a frozen snapshot of
the *current* machine; `layout.sh` is the parameterized, forward-looking version of the same thing.

## Host

- Ubuntu 26.04 LTS (`resolute`), user `lamb`, login shell bash.
- Disk: `nvme0n1`, 476.9 GiB, **GPT**.

## Partitions

| Part | Size | GPT type | Type GUID | Filesystem | Mount |
|------|------|----------|-----------|------------|-------|
| `nvme0n1p1` | 1 GiB | EFI System | `c12a7328-f81f-11d2-ba4b-00a0c93ec93b` | vfat (`E4FA-5AED`) | `/boot/efi` |
| `nvme0n1p2` | 1 GiB | Linux filesystem | `0fc63daf-8483-4772-8e79-3d69d8477de4` | ext4 (`f8cf2ee6-…`) | `/boot` (unencrypted) |
| `nvme0n1p4` | 474.9 GiB | Linux LUKS | `ca7d7ccb-63ed-4c53-861c-1742536059cc` | crypto_LUKS (`46bbc01e-…`) | — |

> **No `p3`.** The live disk has a numbering gap (a prior partition was removed). A `fresh` run
> produces contiguous `p1/p2/p3`, so the LUKS partition is `p3` on a freshly-provisioned disk but
> `p4` here. `reinstall` discovers the LUKS partition by type, so it handles either.
>
> **No swap** — none configured; matched intentionally.

## LUKS

- Container: `nvme0n1p4` (UUID `46bbc01e-1a48-4a3e-ad40-5e7f62fc6866`).
- Mapper: `cryptroot` → `/dev/mapper/cryptroot`.
- `/etc/crypttab`: `cryptroot UUID=46bbc01e-… none luks,discard`
  (`none` = unlock by **interactive passphrase**, no keyfile).
- Cipher / KDF: _to be filled in_ from `sudo cryptsetup luksDump /dev/nvme0n1p4`
  (documentation only; `fresh` uses current cryptsetup LUKS2 defaults rather than pinning these).

## btrfs

Single filesystem on `/dev/mapper/cryptroot` (UUID `e7d58fcc-1037-4825-a414-9b5eeeccb487`).
Common mount options: `noatime,compress=zstd:1,discard=async,space_cache=v2`.

| Subvolume | Mount | Persistence | Notes |
|-----------|-------|-------------|-------|
| `@main_ubt26` | `/` | recreate | OS root (versioned for Ubuntu 26) |
| `@main_ubt26_home` | `/home` | recreate | |
| `@main_ubt26_log` | `/var/log` | recreate | |
| `@main_ubt26_snapshots` | `/.snapshots` | recreate | snapper target; holds nested snapshot subvols |
| `@space` | `/space` | **preserve** | shared; survives OS reinstall (this repo lives here) |
| `@archives` | `/archives` | **preserve** | shared; `compress=zstd:5` |

The `@main_ubt26*` prefix is OS-versioned and disposable; `@space`/`@archives` are unversioned and
shared across distro reinstalls. Reproducing that split is the whole point of `00-provision`.

## Related on-machine setup (belongs to 10-bootstrap, captured here for context)

- snapper configs: `root`, `home`, `space`.
- snapper-rollback + grub-btrfs (see `/space/tool_scripts/setup_snapper_rollback.sh`).
