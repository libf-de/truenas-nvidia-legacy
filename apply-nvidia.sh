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
ldconfig                       # /etc/ld.so.cache is not covered by the sysext
systemctl daemon-reload        # pick up nvidia-legacy-modules.service

# multi-user.target is long since active, so the .wants symlink the sysext ships
# only takes effect on the next boot — start it by hand now.
echo "== loading modules + creating device nodes"
systemctl start nvidia-legacy-modules.service || {
  echo "unit failed:"; systemctl status --no-pager -l nvidia-legacy-modules.service; exit 1; }

nvidia-smi

echo "== checking Vulkan prerequisites"
# The NVIDIA Vulkan ICD does not initialise without nvidia-modeset.
lsmod | grep -q '^nvidia_modeset ' \
  || echo "WARN: nvidia_modeset not loaded — Vulkan will fail to initialise"
for n in /dev/nvidiactl /dev/nvidia0 /dev/nvidia-modeset; do
  [[ -e $n ]] || echo "WARN: $n missing"
done
[[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]] \
  || echo "WARN: /usr/share/vulkan/icd.d/nvidia_icd.json missing"
# libnvidia-container resolves what to bind-mount into a container out of the
# host ldcache, so a library missing here is invisible to GPU containers.
for l in libGLX_nvidia.so.0 libnvidia-glvkspirv.so libnvidia-glcore.so; do
  ldconfig -p | grep -q "$l" || echo "WARN: $l not in the ldcache"
done

# dockerd execs the hook by name; if it isn't on PATH every `--gpus` container
# fails with: exec: "nvidia-container-runtime-hook": executable file not found in $PATH
for b in nvidia-container-runtime-hook nvidia-container-runtime nvidia-ctk nvidia-container-cli; do
  command -v "$b" >/dev/null || echo "WARN: $b not on PATH after merge"
done
[[ -f /etc/nvidia-container-runtime/config.toml ]] \
  || echo "WARN: /etc/nvidia-container-runtime/config.toml missing (a sysext cannot ship /etc) — run: nvidia-ctk config default --output /etc/nvidia-container-runtime/config.toml"

echo
echo "done. rollback: zfs rollback $SNAP  (after systemd-sysext unmerge)"
echo "restart your GPU containers now."
echo "for Vulkan in a container, the GL/Vulkan libraries are only bind-mounted"
echo "when NVIDIA_DRIVER_CAPABILITIES includes 'graphics' (or is 'all')."
