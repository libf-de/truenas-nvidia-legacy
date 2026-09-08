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

The shipped `nvidia.raw` carries more than the driver, though — it also ships
the NVIDIA container toolkit (`nvidia-ctk`, `nvidia-container-runtime`,
`nvidia-container-cli`, `libnvidia-container.so.1`, ...) and the full driver
userland (libcuda, NVENC/NVDEC, ...). Since our output *replaces* that file,
the build **overlays onto a copy of the stock raw** instead of building a
modules-only sysext. Everything we don't touch stays exactly at the version
TrueNAS shipped, and Docker GPU passthrough keeps working.

## How it works

1. Pulls the TrueNAS-built `linux-headers-truenas-production-amd64` `.deb`
   straight from the TrueNAS download mirror — no NAS access needed.
2. In a `debian:bookworm` Docker builder, extracts
   `NVIDIA-Linux-x86_64-<version>.run` and compiles `nvidia.ko` /
   `nvidia-modeset.ko` / `nvidia-uvm.ko` / `nvidia-drm.ko` against those
   headers.
3. `unsquashfs`es the stock `orig/nvidia.raw` into a staging tree, then
   overlays onto it: our `.ko` files (into whatever directory the stock raw
   used), the regenerated `modules.dep`/`modules.alias`/… , and our
   `nvidia-smi` / `libnvidia-ml.so*` / `libnvidia-cfg.so*` at the stock paths.
   Every kernel module the stock raw carried is deleted first, so no
   open-flavour `.ko` survives. The stock `extension-release.nvidia` is kept if
   it already declares `ID=_any`.
4. `mksquashfs` → `nvidia.raw`.

The image self-checks before packing: `nvidia-container-runtime-hook`,
`nvidia-container-runtime`, `nvidia-ctk` and `nvidia-container-cli` are all
executable in `/usr/bin` (dockerd resolves the hook via `$PATH`, so anywhere
else doesn't count), `libnvidia-container.so.1` is present, `nvidia.ko` reports
`license: NVIDIA` (proprietary flavour) and the target vermagic, and the set of
shipped modules equals the set just built.

If the staged tree is missing any of those binaries — including on the overlay
path, when the stock raw turns out not to carry them — the build fills the gaps
from NVIDIA's apt repo. Existing files are never overwritten, so the stock
userland always wins. Without this, GPU containers fail with:

```
Error response from daemon: exec: "nvidia-container-runtime-hook": executable file not found in $PATH
```

## Local build

Requirements: Docker, plus a copy of the stock sysext at `orig/nvidia.raw`.

Grab it off the NAS **before** overwriting it:

```sh
mkdir -p orig
scp root@truenas.local:/usr/share/truenas/sysext-extensions/nvidia.raw orig/
```

Already overwrote it? Pull it out of a ZFS snapshot of the `/usr` dataset:

```sh
ls /usr/.zfs/snapshot/<snap>/share/truenas/sysext-extensions/nvidia.raw
```

Then:

```sh
./build.sh
```

Output: `out/nvidia.raw`.

### Building without the stock raw (fallback)

```sh
CTK_FALLBACK=1 ./build.sh
```

This skips the overlay and instead adds NVIDIA's apt repo in the builder,
`dpkg -x`-ing `nvidia-container-toolkit`, `nvidia-container-toolkit-base`,
`libnvidia-container1` and `libnvidia-container-tools` into the staging tree.
You get the container toolkit but **not** the rest of the stock userland
(libcuda, NVENC/NVDEC, …), so anything on the host that linked against those
breaks. Prefer the overlay path.

Note: `/etc/nvidia-container-runtime/config.toml` is not covered by a sysext
(sysexts only extend `/usr` and `/opt`), so it has to exist on the host
already — it does if the stock raw was ever merged.

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

The runner has no route to the NAS, so the stock raw has to come over HTTP:
set the optional `orig_raw_url` input to somewhere the runner can `curl` a
copy of `/usr/share/truenas/sysext-extensions/nvidia.raw` from. Left empty,
the job takes the fallback path above and says so in the job summary.

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
  so this overwrites the shipped `nvidia.raw`. Keep a copy of the original —
  it is also the *build input*.
- **Supersedes the stock raw wholesale.** The output is not a modules-only
  sysext: it is the stock extension with our modules and matching `nvidia-smi`
  / `libnvidia-ml` swapped in, so it carries the container toolkit and the
  whole driver userland too. Rebuild it against the new stock raw after any
  TrueNAS upgrade that bumps the driver — installing an old build over a newer
  stock raw would roll that userland back.
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
