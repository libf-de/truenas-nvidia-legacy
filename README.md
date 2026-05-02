# truenas-nvidia-legacy

Builds a `systemd-sysext` extension that replaces TrueNAS Scale 25.10's
shipped *open-kernel-module* NVIDIA driver with the **proprietary** flavour of
the same release, so that pre-Turing GPUs (Maxwell / Pascal / Volta) keep
working.

TrueNAS 25.10 ("Goldeye") switched to NVIDIA's open kernel modules, which
require a GPU System Processor (GSP) on the silicon — Pascal and older lack
that, so `nvidia.ko` refuses to bind:

```
NVRM: The NVIDIA GPU 0000:17:00.0 (PCI ID: 10de:1bb3) installed in this system
NVRM: is not supported by open nvidia.ko because it does not include the
NVRM: required GPU System Processor (GSP).
```

The proprietary `570.172.08` userland is unchanged between the two flavours,
so we only need to swap the kernel modules (and ship the matching `nvidia-smi`
/ `libnvidia-ml.so` so version-magic stays consistent).

## How it works

1. Pulls the TrueNAS-built `linux-headers-truenas-production-amd64` `.deb`
   straight from the TrueNAS download mirror — no NAS access needed.
2. In a `debian:bookworm` Docker builder, extracts
   `NVIDIA-Linux-x86_64-<version>.run` and compiles `nvidia.ko` /
   `nvidia-modeset.ko` / `nvidia-uvm.ko` / `nvidia-drm.ko` against those
   headers.
3. Stages the modules under
   `usr/lib/modules/<kver>/extra/nvidia/`, plus `nvidia-smi` and
   `libnvidia-ml.so*`, plus an `extension-release.nvidia` file with
   `ID=_any` (matches what TrueNAS's own sysext declares).
4. `mksquashfs` → `nvidia.raw`.

## Local build

Requirements: Docker.

```sh
./build.sh
```

Output: `out/nvidia.raw`.

To target a different driver, kernel, or headers URL:

```sh
docker build \
  --build-arg NVIDIA_DRIVER_VERSION=570.172.08 \
  --build-arg KERNEL_RELEASE=6.12.33-production+truenas \
  --build-arg KERNEL_HEADERS_URL=https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.0/packages/linux-headers-truenas-production-amd64_6.12.33-production+truenas-1_amd64.deb \
  -t tn-nvidia-legacy-builder .
docker run --rm tn-nvidia-legacy-builder > out/nvidia.raw
```

## GitHub Actions build

`.github/workflows/build.yml` is a `workflow_dispatch` job. Inputs default to
the TrueNAS 25.10.3 / kernel 6.12.33 / driver 570.172.08 combination — for
that target, just hit "Run workflow". The `nvidia.raw` artefact is attached
to the run.

Override the inputs to retarget a different TrueNAS version: bump
`kernel_release` and `kernel_headers_url` together (the URL is published
per-TrueNAS-release at `https://download.truenas.com/TrueNAS-SCALE-<train>/<version>/packages/`).
The kernel only changes on minor TrueNAS releases, so the `25.10.0` headers
deb is reused across the 25.10.x point releases that share kernel 6.12.33.

## Installing on TrueNAS

`/usr` lives on a read-only ZFS dataset; the install flips it off, drops the
file in, and flips it back. **TrueNAS upgrades will overwrite this file** —
re-copy after each upgrade, or script it via a post-init task.

```sh
scp out/nvidia.raw root@truenas.local:/tmp/nvidia.raw

# on the NAS:
POOL=$(zfs list -H -o name | awk '/\/usr$/{print; exit}')
zfs set readonly=off "$POOL"
cp /tmp/nvidia.raw /usr/share/truenas/sysext-extensions/nvidia.raw
zfs set readonly=on "$POOL"

systemd-sysext merge
ldconfig                          # rebuild /etc/ld.so.cache so the new libnvidia-ml.so.1 is found
modprobe nvidia && nvidia-smi
```

Note: if a previous sysext is already merged, run `systemd-sysext unmerge`
*before* flipping the dataset to `readonly=off` — the overlay otherwise
blocks ZFS from remounting it. `ldconfig` is needed once after install
because `/etc/ld.so.cache` lives in `/etc` (not extended by the sysext)
and won't see the new SONAME otherwise.

Snapshot the dataset before the first install if you want a quick rollback.

## Caveats

- **Replaces, not augments.** Two sysexts owning `nvidia.ko` would conflict,
  so this overwrites the shipped `nvidia.raw`. Keep a copy of the original.
- **Version magic.** TrueNAS 25.10 + kernel 6.12 ships built with gcc-12,
  which is also `debian:bookworm`'s default — vermagic should line up. If
  `modprobe nvidia` complains about version-magic mismatch, the toolchain
  drifted and the builder needs pinning.
- **No module signing.** Fine with Secure Boot off. With Secure Boot on,
  modules need to be signed against an enrolled MOK.
- **Driver/userland version must match.** The shipped TrueNAS sysext provides
  `nvidia-smi` / `libnvidia-ml` of a specific version. Build at the *same*
  driver version (proprietary flavour) so anything else on the host that
  links against the userland keeps working.
