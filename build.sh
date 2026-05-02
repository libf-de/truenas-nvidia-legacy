#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building docker image"
docker build -t tn-nvidia-legacy-builder .

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
