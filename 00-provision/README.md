# 00-provision — disk → LUKS2 → btrfs subvolumes

Takes a disk to a **prepared target**: GPT-partitioned, LUKS2-encrypted, btrfs made, subvolumes
created per [`layout.sh`](layout.sh), everything mounted under a target root with `fstab`/`crypttab`
written into it.

## ⚠️ Boundary — what this does NOT do

This produces a **prepared, mounted target — not a bootable system.** Installing the OS onto the
mounts (debootstrap / installer) and the bootloader (GRUB cryptodisk + grub-btrfs) belong to
`../10-bootstrap` and are not built yet. Layer 0 automates the painful btrfs/LUKS-subvolume part and
stops at a clean seam.

## Files

| File | Role |
|------|------|
| [`layout.sh`](layout.sh) | **Declarative layout** — disk, partitions, LUKS name, subvolume table. Hand-edit to retarget, or generate a per-machine `layout.<machine>.sh` with `configure.sh`. |
| [`configure.sh`](configure.sh) | **Interactive layout wizard** (whiptail) — pick disk, size partitions, toggle subvolumes; writes a validated `layout.<machine>.sh`. Generator only: read-only disk probing, no destructive ops, never stores the passphrase. |
| [`provision.sh`](provision.sh) | Orchestrator + step functions. |
| [`lib/common.sh`](lib/common.sh) | Logging, dry-run runner, guards, confirmation, failure cleanup. |
| [`reference/this-machine.md`](reference/this-machine.md) | Frozen capture of the current machine. |

## Configuring a layout

Two ways to produce the layout `provision.sh` consumes:

- **Hand-edit** [`layout.sh`](layout.sh) — the reference/default. Best for unattended runs (every
  knob is env-overridable).
- **Interactive wizard** — `./configure.sh` walks you through disk selection, partition sizing (with
  free-space validation), OS tag, LUKS mapper name, and which subvolumes to create, then writes a
  tracked **`layout.<machine>.sh`**. It runs **no disk operations** (read-only probing only) and
  never writes the LUKS passphrase. Hand it to the engine with `LAYOUT=`:

  ```bash
  ./configure.sh                                              # writes layout.<machine>.sh
  sudo LAYOUT=layout.<machine>.sh ./provision.sh fresh --dry-run
  sudo LAYOUT=layout.<machine>.sh ./provision.sh fresh --yes
  ```

  Needs `whiptail` (preinstalled on Ubuntu live; else `sudo apt-get install -y whiptail`). The
  generated file is committed as the reproducible record of that machine. Note the wizard targets
  the `fresh` workflow; `reinstall` is still driven from the CLI (bump `OS_TAG`, run
  `provision.sh reinstall`).

## Workflows

```
sudo ./provision.sh fresh        # wipe DISK, build the entire layout from scratch
sudo ./provision.sh reinstall    # keep `preserve` subvols, recreate only `recreate` subvols
```

- **`fresh`** — for a blank disk or a full reset. Partitions, LUKS-formats (prompts for a
  passphrase), makes filesystems, creates *all* subvolumes, mounts. **Destroys everything**,
  including `@space`/`@archives`.
- **`reinstall`** — the multi-distro path. Opens the *existing* LUKS container, and recreates only
  the OS-versioned (`recreate`) subvolumes while leaving the shared (`preserve`) ones — `@space`,
  `@archives` — untouched. This is what lets you reinstall the OS without losing data subvolumes.

`reinstall` runs a **preflight** before deleting anything: it enumerates existing subvolumes,
**refuses** if there are unknown top-level subvolumes not in `layout.sh` (override with
`ALLOW_UNKNOWN_SUBVOLS=1`), and **asserts no `preserve` subvolume sits inside a `recreate` target**.
Only then does it recursively delete and recreate the OS subvolumes (handling nested subvolumes such
as snapper snapshots, deepest-first).

Single steps are available for inspection/manual use:
`partition | luks | mkfs | subvols | mount | gen-tab`.

## Safety model

- **Dry-run by default.** Every invocation prints the exact commands and changes *nothing*. Add
  `--yes` to actually execute.
- A real run **requires root**, **refuses** a disk that is mounted or that hosts the running system,
  and makes you **type the target device path** to confirm (or set `CONFIRM_DEVICE=<dev>` for
  automation).
- **Refuses if `/dev/mapper/$LUKS_NAME` already exists** (it could be the running system's mapper),
  and **asserts the mapper is backed by the target partition** before any `mkfs` or subvolume
  delete — so a name collision can never redirect operations onto a live device.
- `set -Eeuo pipefail` + a cleanup `trap`: a mid-run failure unwinds mounts and closes the LUKS
  mapper, so the disk is never left half-formatted with an open mapper. (Mounts are *kept* on
  success — the next step installs the OS onto them.)
- Not idempotent — a wipe re-wipes. It is *safe and re-runnable behind these guards*.

## Typical usage (from an Ubuntu live USB)

```bash
sudo apt-get install -y gdisk cryptsetup btrfs-progs dosfstools whiptail   # if missing
./configure.sh                        # interactive: pick disk, sizes, subvols → layout.<machine>.sh
#   (or hand-edit layout.sh directly, then drop the LAYOUT= below)
sudo LAYOUT=layout.<machine>.sh ./provision.sh fresh --dry-run   # review the plan
sudo LAYOUT=layout.<machine>.sh ./provision.sh fresh --yes       # execute; enter LUKS passphrase when prompted
# target is now mounted at /mnt/target — hand off to OS install (10-bootstrap, TBD)
```

## Tuning knobs (env)

| Var | Default | Purpose |
|-----|---------|---------|
| `DISK` | `/dev/nvme0n1` | target whole-disk device (also settable in `layout.sh`) |
| `OS_TAG` | `main_ubt26` | versioned prefix for disposable OS subvolumes |
| `LUKS_NAME` | `cryptroot` | dm-crypt mapper name; **must be unique vs. any running system's mapper** |
| `TARGET` | `/mnt/target` | where the prepared tree is mounted |
| `LAYOUT` | `./layout.sh` | path to an alternate layout file |
| `LUKS_PASSPHRASE` | _unset_ | non-interactive LUKS passphrase (unattended installs / tests); if unset, cryptsetup prompts |
| `CONFIRM_DEVICE` | _unset_ | pre-supply the typed device confirmation (automation) |
| `ALLOW_UNKNOWN_SUBVOLS` | `0` | let `reinstall` proceed past unknown top-level subvolumes |

## Testing

[`test/loopback-test.sh`](test/loopback-test.sh) exercises the real (non-dry-run) path safely
against a throwaway loopback image — never a real disk. It verifies `fresh` creates all
subvolumes + tabs, that a marker written into `@space` **survives** a `reinstall` while OS
subvolumes (and a nested test subvolume) are recreated, and that `reinstall` **refuses** an unknown
top-level subvolume. Run as root: `sudo ./test/loopback-test.sh`.

[`test/configure-test.sh`](test/configure-test.sh) unit-tests `configure.sh`'s pure logic (size
parsing, capacity math, validators, subvolume assembly, layout rendering) with **no TTY, root, or
disk access**. It sources the wizard and asserts that the generated layout re-sources into a valid
`SUBVOLS`, that `DISK` is hardcoded while `OS_TAG` stays env-overridable, that the wizard's template
doesn't drift from `layout.sh`, and that **no secret material** is ever written. Run:
`./test/configure-test.sh`.
