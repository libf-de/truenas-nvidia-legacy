#!/usr/bin/env bash
# Swap TrueNAS' shipped nvidia sysext for the proprietary-flavour build.
# Usage: ./install-nvidia-legacy.sh /tmp/nvidia.raw
set -euo pipefail

SRC="${1:?usage: $0 /path/to/nvidia.raw}"
DST=/usr/share/truenas/sysext-extensions/nvidia.raw
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
[[ -f $SRC ]] || { echo "no such file: $SRC"; exit 1; }

POOL=$(grep -m1 '^boot-pool/ROOT/.*/usr$' <<< "$(zfs list -H -o name)")
[[ -n $POOL ]] || { echo "could not find /usr dataset"; exit 1; }
echo "dataset: $POOL"

echo "== unmerging sysexts"
systemd-sysext unmerge
findmnt -no FSTYPE /usr | grep -qx zfs || {
  echo "/usr still not plain zfs:"; findmnt /usr; exit 1; }

echo "== unloading nvidia modules"
for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
  lsmod | grep -q "^$m " && rmmod "$m"
done

SNAP="$POOL@pre-nvidia-legacy-$(date +%Y%m%d-%H%M%S)"
echo "== snapshot $SNAP"
zfs snapshot "$SNAP"

restore_ro() { zfs set readonly=on "$POOL" || true; }
trap restore_ro EXIT

echo "== installing"
zfs set readonly=off "$POOL"
[[ -f $DST.orig ]] || cp -a "$DST" "$DST.orig"   # keep the stock one, once
cp "$SRC" "$DST"
zfs set readonly=on "$POOL"
trap - EXIT

echo "== merging + reloading"
systemd-sysext merge
ldconfig
modprobe nvidia
nvidia-smi

echo
echo "done. rollback: zfs rollback $SNAP  (after systemd-sysext unmerge)"
echo "restart your GPU containers now."
