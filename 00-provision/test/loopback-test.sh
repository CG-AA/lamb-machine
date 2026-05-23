#!/usr/bin/env bash
#
# loopback-test.sh — exercise provision.sh's real (non-dry-run) path SAFELY against a
# throwaway loopback image. Never touches a real disk. Run as root:  sudo ./loopback-test.sh
#
# Verifies:
#   1. `fresh` creates every subvolume and writes fstab/crypttab
#   2. a marker written into @space SURVIVES `reinstall` (the multi-distro guarantee)
#   3. OS subvols — including a nested test subvol — are recreated by `reinstall`
#   4. `reinstall` REFUSES an unknown top-level subvolume (safety preflight)
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$HERE/../provision.sh"

IMG="${IMG:-/tmp/lamb-loopback.img}"   # override if /tmp is a small tmpfs, e.g. IMG=/space/lamb-loopback.img
SIZE="${SIZE:-4G}"                     # sparse; only ~100 MB is actually written
export TARGET="${TARGET:-/mnt/lamb-loopback}"
export OS_TAG="${OS_TAG:-testos}"
export LUKS_PASSPHRASE="${LUKS_PASSPHRASE:-loopback-test-passphrase}"
# Unique mapper name, exported so provision.sh uses it — MUST NOT be the running
# system's "cryptroot", or operations would target the live root device.
export LUKS_NAME="${LUKS_NAME:-lamb_loopback_crypt}"
LOOP=""

pass() { printf '\033[32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31m  FAIL\033[0m %s\n' "$*"; exit 1; }
phase() { printf '\n\033[34m### %s\033[0m\n' "$*"; }

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root: sudo $0"; exit 1; }

# Simulate booting a fresh live USB: nothing of ours mounted/open.
teardown_runtime() {
  if mountpoint -q "$TARGET" 2>/dev/null; then umount -R "$TARGET" || true; fi
  # unmount anything else still backed by our mapper (e.g. a stray top-level mount)
  local mp
  while read -r mp; do
    [[ -n "$mp" ]] || continue
    umount -R "$mp" 2>/dev/null || true
  done < <(findmnt -nro TARGET -S "/dev/mapper/$LUKS_NAME" 2>/dev/null)
  if [[ -e "/dev/mapper/$LUKS_NAME" ]]; then cryptsetup close "$LUKS_NAME" || true; fi
}

cleanup() {
  set +e
  teardown_runtime
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  rm -f "$IMG"
  rmdir "$TARGET" 2>/dev/null
}
trap cleanup EXIT

# Mount the btrfs top-level of the loop device at a fresh tmpdir; echo the path.
mount_toplevel() {
  local d; d="$(mktemp -d)"
  mount -o subvolid=5 "/dev/mapper/$LUKS_NAME" "$d"
  echo "$d"
}

phase "create loopback image ($SIZE) and attach"
truncate -s "$SIZE" "$IMG"
LOOP="$(losetup -fP --show "$IMG")"
export DISK="$LOOP" CONFIRM_DEVICE="$LOOP"
echo "  loop device: $LOOP   (OS_TAG=$OS_TAG)"

phase "fresh --yes"
"$PROV" fresh --yes

phase "verify fresh result"
top="$(mount_toplevel)"
mapfile -t subvols < <(btrfs subvolume list "$top" | sed -n 's/.* path //p' | sort)
expected=("@archives" "@space" "@${OS_TAG}" "@${OS_TAG}_home" "@${OS_TAG}_log" "@${OS_TAG}_snapshots")
for e in "${expected[@]}"; do
  printf '%s\n' "${subvols[@]}" | grep -qx "$e" || fail "subvolume $e missing after fresh"
done
pass "all ${#expected[@]} subvolumes present: ${subvols[*]}"
umount "$top"; rmdir "$top"

grep -q "subvol=@${OS_TAG}\b" "$TARGET/etc/fstab" || fail "fstab missing root subvol entry"
grep -q "^$LUKS_NAME" "$TARGET/etc/crypttab" || fail "crypttab missing mapper entry"
pass "fstab + crypttab generated"

phase "seed data: marker in @space + nested subvol under @${OS_TAG}_log"
marker="preserve-me-$RANDOM"
echo "$marker" > "$TARGET/space/MARKER"
btrfs subvolume create "$TARGET/var/log/nested-test" >/dev/null
pass "wrote @space/MARKER and created nested subvol @${OS_TAG}_log/nested-test"

phase "reinstall --yes (simulating a fresh live USB boot)"
teardown_runtime
"$PROV" reinstall --yes

phase "verify reinstall preserved data + recreated OS subvols"
if [[ "$(cat "$TARGET/space/MARKER")" == "$marker" ]]; then
  pass "@space marker SURVIVED reinstall"
else
  fail "@space marker was LOST"
fi
if [[ ! -e "$TARGET/var/log/nested-test" ]]; then
  pass "OS subvol recreated (nested subvol gone)"
else
  fail "OS subvol was NOT recreated (nested subvol still present)"
fi

phase "negative test: reinstall must REFUSE an unknown top-level subvol"
teardown_runtime
# open the (fresh-created) LUKS at p3 and add a stray subvol the layout doesn't know about
printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --key-file=- "${LOOP}p3" "$LUKS_NAME"
top="$(mount_toplevel)"
btrfs subvolume create "$top/@stray" >/dev/null
umount "$top"; rmdir "$top"
teardown_runtime
if "$PROV" reinstall --yes >/dev/null 2>&1; then
  fail "reinstall did NOT refuse unknown subvol @stray"
else
  pass "reinstall correctly refused unknown subvol @stray"
fi

printf '\n\033[32m### ALL TESTS PASSED\033[0m\n'
