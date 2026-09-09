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
   used), the `modules.dep`/`modules.alias`/… regenerated for *that* directory,
   our `nvidia-smi`, the Vulkan/GL userland, `nvidia-modprobe`, the Vulkan ICD
   manifest and a `nvidia-legacy-modules.service` that loads the modules at
   boot. Every kernel module the stock raw carried is deleted first, so no
   open-flavour `.ko` survives. The stock `extension-release.nvidia` is kept if
   it already declares `ID=_any`.
4. `mksquashfs` → `nvidia.raw`.

The image self-checks before packing: `nvidia-container-runtime-hook`,
`nvidia-container-runtime`, `nvidia-ctk` and `nvidia-container-cli` are all
executable in `/usr/bin` (dockerd resolves the hook via `$PATH`, so anywhere
else doesn't count), `libnvidia-container.so.1` is present, `nvidia.ko` reports
`license: NVIDIA` (proprietary flavour) and the target vermagic, the set of
shipped modules equals the set just built, every path the shipped `modules.dep`
names for our modules exists in the tree, and the Vulkan pieces below are all
in place.

If the staged tree is missing any of those binaries — including on the overlay
path, when the stock raw turns out not to carry them — the build fills the gaps
from NVIDIA's apt repo. Existing files are never overwritten, so the stock
userland always wins. Without this, GPU containers fail with:

```
Error response from daemon: exec: "nvidia-container-runtime-hook": executable file not found in $PATH
```

## Vulkan

The stock sysext is a compute-oriented build: it gets `nvidia-smi` and CUDA
working, but nothing loads `nvidia-modeset.ko`, no device nodes are created for
it, and the graphics userland is not guaranteed to be there. NVIDIA's Vulkan ICD
needs all three. The build therefore also ships:

- **`nvidia-modeset.ko` actually loaded at boot.** The ICD fails to initialise
  without it. `/usr/lib/systemd/system/nvidia-legacy-modules.service` runs
  `nvidia-modprobe -m -u -c 0`, which loads `nvidia`, `nvidia-modeset` and
  `nvidia-uvm` and creates `/dev/nvidiactl`, `/dev/nvidia0`,
  `/dev/nvidia-modeset` and the dynamic-major `/dev/nvidia-uvm*` nodes. It ships
  pre-enabled through a `.wants` symlink under `/usr/lib/systemd/system`, since
  a sysext cannot write `/etc`.

  A `modules-load.d` drop-in would have been simpler but does not work here:
  `systemd-modules-load.service` and `systemd-sysext.service` are both only
  ordered `Before=sysinit.target`, with no ordering relative to each other, and
  the former's `ConditionDirectoryNotEmpty` is evaluated before the merge — so
  it races the merge and usually loses. A unit wanted by `multi-user.target`
  runs well after it.

- **The 64-bit graphics libraries**, taken from the same `.run` as the modules
  so the versions cannot drift: `libGLX_nvidia` (the ICD itself),
  `libnvidia-glcore`, `libnvidia-glvkspirv` (the SPIR-V compiler),
  `libnvidia-glsi`, `libnvidia-tls`, `libnvidia-eglcore`, plus `libnvidia-rtcore`
  and `libnvidia-vulkan-producer` when the branch has them. Each is installed
  with the `SONAME` symlink read out of the library's own `DT_SONAME`, because
  `ldconfig` cannot create it once `/usr` is a read-only sysext.

- **`/usr/share/vulkan/icd.d/nvidia_icd.json`**, from the `.run`'s template.
  Host Mesa ICDs in that directory are not shadowed — a merged sysext overlays
  the directory, so both stay visible.

- **`nvidia-modprobe`** in `/usr/bin`, so anything that opens the driver can
  create the nodes on demand too.

Two things this does *not* do:

- It does not ship glvnd (`libGLdispatch.so.0`, `libGL.so.1`, …). Those belong
  to the host's and the container's own libglvnd; overwriting them from the
  `.run` would hijack every other GL user on the NAS.
- It does not touch `libcuda`. On the overlay path that still comes from the
  stock raw.

Inside a container, libnvidia-container only bind-mounts the graphics libraries
and the ICD manifest when `NVIDIA_DRIVER_CAPABILITIES` includes `graphics` (or
is `all`) — the default is `utility,compute`, which gets you `nvidia-smi` and
CUDA but no Vulkan. It resolves what to mount out of the **host ldcache**, so
`ldconfig` has to have run on the host after the merge (the install steps below
do this) or the libraries are invisible to the container even though they are
on disk.

Driver branch matters: Vulkan 1.3 needs ≥ 510. The 470 legacy branch tops out
at 1.2 and any engine requiring 1.3 will reject the device. 570.x is the right
target for Pascal — it is Vulkan 1.3 capable, and Pascal was dropped in 580.

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
You get the container toolkit, and the Vulkan/GL libraries come out of the
`.run` either way, but **not** the rest of the stock userland (libcuda,
NVENC/NVDEC, …), so anything on the host that linked against those breaks.
Prefer the overlay path.

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
ldconfig                          # rebuild /etc/ld.so.cache so the new SONAMEs are found
systemctl daemon-reload
systemctl start nvidia-legacy-modules.service
nvidia-smi
```

`apply-nvidia.sh` does all of the above plus a ZFS snapshot, a one-time backup
of the stock raw to `nvidia.raw.orig`, and post-install checks (`nvidia_modeset`
loaded, device nodes present, ICD manifest found, GL libraries in the ldcache):

```sh
scp apply-nvidia.sh out/nvidia.raw root@truenas.local:/tmp/
ssh root@truenas.local '/tmp/apply-nvidia.sh /tmp/nvidia.raw'
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
- **GPU isolation for VMs still works.** TrueNAS applies isolation from the
  initramfs (it writes the PCI IDs into `/etc/modprobe.d/vfio.conf`,
  `/etc/modprobe.d/nvidia.conf`, `/etc/modules` and
  `/etc/initramfs-tools/modules`), so `vfio-pci` has claimed the isolated
  devices long before `nvidia-legacy-modules.service` runs at
  `multi-user.target` — the unit cannot take a GPU away from a VM. It also goes
  through `modprobe(8)` rather than `insmod`, so the middleware-generated
  `/etc/modprobe.d/nvidia.conf` is honoured, and it skips itself (exit 0, no
  failed unit) when every NVIDIA GPU in the box is bound to `vfio-pci`.
- **Driver/userland version must match.** The shipped TrueNAS sysext provides
  `nvidia-smi` / `libnvidia-ml` of a specific version. Build at the *same*
  driver version (proprietary flavour) so anything else on the host that
  links against the userland keeps working.
