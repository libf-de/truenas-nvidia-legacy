#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# The output replaces TrueNAS's shipped nvidia.raw wholesale, so we overlay onto
# a copy of that raw rather than building a modules-only sysext — otherwise the
# NVIDIA container toolkit and the rest of the driver userland disappear on
# install and Docker GPU passthrough breaks.
CTK_FALLBACK="${CTK_FALLBACK:-0}"

if [[ ! -f orig/nvidia.raw ]]; then
  if [[ "${CTK_FALLBACK}" != "1" ]]; then
    cat >&2 <<'ERR'
ERROR: orig/nvidia.raw not found.

This build overlays onto TrueNAS's stock nvidia.raw so the output keeps the
NVIDIA container toolkit (nvidia-ctk, nvidia-container-runtime,
libnvidia-container.so.1, ...) and the full driver userland. Get a copy:

  # on the NAS, BEFORE overwriting the file:
  scp root@truenas.local:/usr/share/truenas/sysext-extensions/nvidia.raw orig/

  # already overwrote it? pull it out of a snapshot of the /usr dataset:
  ls /usr/.zfs/snapshot/<snap>/share/truenas/sysext-extensions/nvidia.raw

Then re-run ./build.sh.

To build without it (container toolkit fetched from NVIDIA's apt repo, rest of
the stock userland NOT included):

  CTK_FALLBACK=1 ./build.sh
ERR
    exit 1
  fi
  echo "==> orig/nvidia.raw absent — using the NVIDIA-repo fallback for the container toolkit"
fi

echo "==> Building docker image"
docker build --build-arg "CTK_FALLBACK=${CTK_FALLBACK}" -t tn-nvidia-legacy-builder .

mkdir -p out
echo "==> Extracting nvidia.raw"
docker run --rm tn-nvidia-legacy-builder > out/nvidia.raw
ls -lh out/nvidia.raw

cat <<'EOF'

==> Done. To install on TrueNAS:

  scp out/nvidia.raw root@truenas.local:/tmp/nvidia.raw

  # on the NAS:
  POOL=$(zfs list -H -o name | awk '/\/usr$/{print; exit}')
  systemd-sysext unmerge
  zfs set readonly=off "$POOL"
  cp /tmp/nvidia.raw /usr/share/truenas/sysext-extensions/nvidia.raw
  zfs set readonly=on "$POOL"
  systemd-sysext merge
  ldconfig
  modprobe nvidia && nvidia-smi
EOF
