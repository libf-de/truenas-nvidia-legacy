ARG NVIDIA_DRIVER_VERSION=570.172.08
ARG KERNEL_RELEASE=6.12.33-production+truenas
ARG KERNEL_HEADERS_DIR=linux-headers-truenas-production-amd64
ARG KERNEL_HEADERS_URL=https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.0/packages/linux-headers-truenas-production-amd64_6.12.33-production+truenas-1_amd64.deb
ARG KERNEL_IMAGE_URL=https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.0/packages/linux-image-truenas-production-amd64_6.12.33-production+truenas-1_amd64.deb
# When orig/nvidia.raw is absent: 1 = pull the container toolkit from NVIDIA's
# apt repo instead, 0 = fail the build.
ARG CTK_FALLBACK=1

FROM debian:bookworm AS builder
ARG NVIDIA_DRIVER_VERSION
ARG KERNEL_RELEASE
ARG KERNEL_HEADERS_DIR
ARG KERNEL_HEADERS_URL
ARG KERNEL_IMAGE_URL

SHELL ["/bin/bash", "-eux", "-o", "pipefail", "-c"]

RUN <<EOF
  apt-get -q update
  apt-get install -qy --no-install-recommends \
      build-essential kmod libelf-dev bc bison flex \
      curl ca-certificates gnupg xz-utils squashfs-tools
EOF

# Pull the TrueNAS-built kernel headers .deb directly from the TrueNAS download mirror.
# Extract into a staging dir first — the .deb ships content outside /usr/src/ that
# would otherwise clobber the builder image's /usr/bin/ etc.
RUN <<EOF
  curl -fSsL --retry 3 -o /tmp/headers.deb "${KERNEL_HEADERS_URL}"
  mkdir -p /tmp/headers /usr/src
  dpkg-deb -x /tmp/headers.deb /tmp/headers
  cp -a "/tmp/headers/usr/src/${KERNEL_HEADERS_DIR}" /usr/src/
  test -f "/usr/src/${KERNEL_HEADERS_DIR}/Makefile"
  rm -rf /tmp/headers /tmp/headers.deb
EOF

ENV KSRC=/usr/src/${KERNEL_HEADERS_DIR}

# Pull the matching kernel image .deb so we can run depmod across the full
# in-tree module set + our nvidia modules. We don't ship the in-tree modules
# in the sysext (the host already has them); we only need them so depmod
# generates a complete modules.dep / modules.alias / modules.symbols.
RUN <<EOF
  curl -fSsL --retry 3 -o /tmp/image.deb "${KERNEL_IMAGE_URL}"
  mkdir -p /tmp/image
  dpkg-deb -x /tmp/image.deb /tmp/image
  test -d "/tmp/image/lib/modules/${KERNEL_RELEASE}" \
    || test -d "/tmp/image/usr/lib/modules/${KERNEL_RELEASE}"
  rm /tmp/image.deb
EOF

WORKDIR /build

RUN curl -fSsLO "https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"

RUN sh "NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run" --extract-only --target /build/nv

# Build kernel modules against the TrueNAS kernel
RUN <<EOF
  cd /build/nv/kernel
  make -j"$(nproc)" SYSSRC="${KSRC}" modules
  ls -l *.ko
EOF

# Optional build input: the stock TrueNAS nvidia.raw. Our output *replaces* that
# file, so overlaying onto it is what keeps the container toolkit and the rest of
# the driver userland (libcuda, NVENC/NVDEC, ...) in the shipped extension.
# The bracket glob makes the second source optional — Docker fails a COPY whose
# sources all match nothing, so .gitignore rides along as a guaranteed match.
COPY .gitignore orig/nvidia.ra[w] /orig/

ARG CTK_FALLBACK

# Unpack the stock raw as the staging root, or start from an empty tree.
RUN <<EOF
  if [ -f /orig/nvidia.raw ]; then
    unsquashfs -d /stage /orig/nvidia.raw
    echo stock > /build/stage-mode
  elif [ "${CTK_FALLBACK}" = "1" ]; then
    mkdir -p /stage
    echo fallback > /build/stage-mode
  else
    echo "ERROR: orig/nvidia.raw missing and CTK_FALLBACK=0." >&2
    echo "Copy /usr/share/truenas/sysext-extensions/nvidia.raw off the NAS into orig/." >&2
    exit 1
  fi
  cat /build/stage-mode
EOF

# Pull the container toolkit from NVIDIA's repo when the staging tree doesn't
# already carry it. On the fallback path that's always (empty tree); on the
# overlay path only when the stock raw turns out to be missing pieces — e.g. it
# ships libnvidia-container but not /usr/bin/nvidia-container-runtime-hook,
# which is what dockerd execs for GPU passthrough:
#   Error response from daemon: exec: "nvidia-container-runtime-hook": executable file not found in $PATH
# Existing files are never overwritten (cp -n), so the stock userland wins.
RUN <<EOF
  NEED=0
  for b in nvidia-container-runtime-hook nvidia-container-runtime nvidia-ctk; do
    [ -x "/stage/usr/bin/${b}" ] || NEED=1
  done
  if [ "${NEED}" = "0" ]; then echo "container toolkit already staged"; exit 0; fi

  install -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get -q update

  mkdir -p /tmp/ctk/deb /tmp/ctk/x
  cd /tmp/ctk/deb
  apt-get download -qy \
      nvidia-container-toolkit nvidia-container-toolkit-base \
      libnvidia-container1 libnvidia-container-tools
  for d in *.deb; do dpkg -x "$d" /tmp/ctk/x; done

  # A sysext may only extend /usr and /opt; /etc config has to live on the host.
  rm -rf /tmp/ctk/x/etc /tmp/ctk/x/usr/share/doc /tmp/ctk/x/usr/share/man
  mkdir -p /stage/usr
  cp -a -n /tmp/ctk/x/usr/. /stage/usr/
  rm -rf /tmp/ctk
  ls -l /stage/usr/bin
EOF

# Overlay our proprietary-flavour build onto the staging tree.
RUN <<EOF
  STAGE=/stage
  mkdir -p "${STAGE}/usr/lib/modules"

  # Install into whatever directory the stock raw used for nvidia.ko; only fall
  # back to extra/nvidia when there was nothing to match (fallback path, or a
  # stock raw built for a different kernel release).
  #
  # depmod records module paths relative to /lib/modules/<release>, so we track
  # that directory as a relative path and reuse it verbatim when running depmod
  # below. Installing into the stock directory while depmod ran against a
  # hardcoded extra/nvidia is what produced a modules.dep naming a nonexistent
  # extra/nvidia/nvidia.ko, so `modprobe nvidia-modeset` reported the module as
  # missing while nvidia.ko was loaded.
  MODBASE="${STAGE}/usr/lib/modules/${KERNEL_RELEASE}"
  FOUND="$(find "${MODBASE}" -name 'nvidia.ko*' -printf '%h\n' 2>/dev/null | head -1 || true)"
  RELDIR=extra/nvidia
  case "${FOUND}" in
    "${MODBASE}/"?*) RELDIR="${FOUND#"${MODBASE}/"}" ;;
  esac
  MODDIR="${MODBASE}/${RELDIR}"
  echo "module install dir (relative to the release dir): ${RELDIR}"

  # Drop every kernel module the stock raw shipped — those are the open-flavour
  # builds, and anything we don't overwrite must not survive into the output.
  find "${STAGE}/usr/lib/modules" \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) \
    -print -delete

  mkdir -p "${MODDIR}"
  cp /build/nv/kernel/*.ko "${MODDIR}/"

  # locate the in-tree modules in the linux-image deb (older debs use /lib, newer /usr/lib)
  if [ -d "/tmp/image/usr/lib/modules/${KERNEL_RELEASE}" ]; then
    IMGMOD="/tmp/image/usr/lib/modules/${KERNEL_RELEASE}"
  else
    IMGMOD="/tmp/image/lib/modules/${KERNEL_RELEASE}"
  fi

  # Run depmod over the merged tree (host in-tree modules + ours) so the
  # regenerated index files carry our additions and resolve against the host's
  # module set. We ship only the index files; the in-tree modules stay the host's.
  DEPROOT=/tmp/depmod
  STAGEMOD="${DEPROOT}/lib/modules/${KERNEL_RELEASE}"
  rm -rf "${DEPROOT}"
  mkdir -p "${STAGEMOD}/${RELDIR}"
  cp -a "${IMGMOD}/." "${STAGEMOD}/"
  cp /build/nv/kernel/*.ko "${STAGEMOD}/${RELDIR}/"
  depmod -b "${DEPROOT}" "${KERNEL_RELEASE}"

  # Ship the depmod-generated index files. modules.builtin* and modules.devname
  # depend only on the kernel image, not on our additions, so we leave the host's
  # versions in place. Everything else can change with our nvidia modules.
  mkdir -p "${STAGE}/usr/lib/modules/${KERNEL_RELEASE}"
  for f in modules.dep modules.dep.bin \
           modules.alias modules.alias.bin \
           modules.symbols modules.symbols.bin \
           modules.softdep; do
    if [ -f "${STAGEMOD}/${f}" ]; then
      cp "${STAGEMOD}/${f}" "${STAGE}/usr/lib/modules/${KERNEL_RELEASE}/${f}"
    fi
  done

  # nvidia-smi: overwrite in place wherever the stock raw put it.
  SMI="$(find "${STAGE}/usr" -type f -name nvidia-smi | head -1 || true)"
  SMI="${SMI:-${STAGE}/usr/bin/nvidia-smi}"
  mkdir -p "$(dirname "${SMI}")"
  cp /build/nv/nvidia-smi "${SMI}"
  chmod 0755 "${SMI}"

  # Userspace libraries. Replace every versioned copy the stock raw carries (the
  # version normally matches, so this is an overwrite) and recreate the SONAME
  # symlink from the library's own DT_SONAME — ldconfig cannot create it for us,
  # because /usr is read-only once the sysext is merged.
  #
  # $1 = library basename, $2 = 1 when the build must fail if the .run lacks it.
  install_lib() {
    lib="$1"
    required="$2"
    src="/build/nv/${lib}.so.${NVIDIA_DRIVER_VERSION}"
    if [ ! -f "${src}" ]; then
      if [ "${required}" = 1 ]; then
        echo "ERROR: ${lib}.so.${NVIDIA_DRIVER_VERSION} not shipped by this .run" >&2
        exit 1
      fi
      echo "optional ${lib} not in this driver branch - skipped"
      return 0
    fi
    # Only 64-bit destinations: the .run's 32-bit libraries live under 32/ and we
    # do not ship them, so an i386 directory in the stock raw must not get ours.
    # `|| true`: grep exits 1 when the stage carries no copy at all (always on the
    # fallback path), and pipefail would otherwise abort the build here.
    dirs="$(find "${STAGE}/usr" -name "${lib}.so.*" -printf '%h\n' \
            | grep -v -e i386 -e '/lib32' | sort -u || true)"
    dirs="${dirs:-${STAGE}/usr/lib/x86_64-linux-gnu}"
    soname="$(readelf -d "${src}" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
    soname="${soname:-${lib}.so.${NVIDIA_DRIVER_VERSION}}"
    for d in ${dirs}; do
      mkdir -p "${d}"
      find "${d}" -maxdepth 1 \( -name "${lib}.so" -o -name "${lib}.so.*" \) -delete
      cp "${src}" "${d}/"
      [ "${soname}" = "${lib}.so.${NVIDIA_DRIVER_VERSION}" ] \
        || ln -s "${lib}.so.${NVIDIA_DRIVER_VERSION}" "${d}/${soname}"
      ln -s "${soname}" "${d}/${lib}.so"
      echo "  ${d}/${lib}.so -> ${soname} -> ${lib}.so.${NVIDIA_DRIVER_VERSION}"
    done
  }

  # Required for Vulkan. libGLX_nvidia is the ICD itself; libnvidia-glvkspirv is
  # the SPIR-V compiler, so nothing renders without it.
  for lib in libGLX_nvidia libnvidia-glcore libnvidia-glvkspirv \
             libnvidia-glsi libnvidia-tls libnvidia-eglcore \
             libnvidia-ml libnvidia-cfg; do
    install_lib "${lib}" 1
  done

  # Present only on some branches: no RT cores on Pascal, and the Wayland
  # producer is not built everywhere.
  for lib in libnvidia-rtcore libnvidia-vulkan-producer libnvidia-gpucomp; do
    install_lib "${lib}" 0
  done

  # nvidia-modprobe loads the modules and creates /dev/nvidiactl, /dev/nvidia0,
  # /dev/nvidia-modeset and the dynamic-major /dev/nvidia-uvm* nodes. It goes
  # through modprobe(8), so the /etc/modprobe.d/nvidia.conf that TrueNAS writes
  # when a GPU is isolated for a VM is still honoured.
  install -D -m 0755 /build/nv/nvidia-modprobe "${STAGE}/usr/bin/nvidia-modprobe"

  # Vulkan ICD manifest. Recent .run files ship a template with a placeholder
  # library path; older ones ship the finished JSON.
  mkdir -p "${STAGE}/usr/share/vulkan/icd.d"
  ICD="${STAGE}/usr/share/vulkan/icd.d/nvidia_icd.json"
  if [ -f /build/nv/nvidia_icd.json.template ]; then
    sed 's|__NV_VK_ICD__|libGLX_nvidia.so.0|' \
      /build/nv/nvidia_icd.json.template > "${ICD}"
  elif [ -f /build/nv/nvidia_icd.json ]; then
    cp /build/nv/nvidia_icd.json "${ICD}"
  else
    cat > "${ICD}" <<ICDEOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version": "1.3.0"
    }
}
ICDEOF
  fi
  chmod 0644 "${ICD}"
  cat "${ICD}"

  # Implicit Vulkan layers and the EGL vendor manifest, when the branch has them.
  # libnvidia-container mounts these into GPU containers alongside the ICD when
  # NVIDIA_DRIVER_CAPABILITIES includes "graphics".
  if [ -f /build/nv/nvidia_layers.json ]; then
    install -D -m 0644 /build/nv/nvidia_layers.json \
      "${STAGE}/usr/share/vulkan/implicit_layer.d/nvidia_layers.json"
  fi
  if [ -f /build/nv/10_nvidia.json ]; then
    install -D -m 0644 /build/nv/10_nvidia.json \
      "${STAGE}/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
  fi

  # Report what libGLX_nvidia pulls in. glvnd (libGLdispatch.so.0) is deliberately
  # not shipped: it belongs to the host's/container's libglvnd, and overwriting it
  # from the .run would hijack every other GL user on the NAS.
  GLX="$(find "${STAGE}/usr" -name 'libGLX_nvidia.so.'"${NVIDIA_DRIVER_VERSION}" | head -1 || true)"
  readelf -d "${GLX}" | grep NEEDED || true

  # Boot-time module load. NVIDIA's Vulkan ICD fails to initialise unless
  # nvidia-modeset.ko is loaded, and nothing on TrueNAS loads it on its own.
  #
  # A modules-load.d drop-in is not usable here: systemd-modules-load.service and
  # systemd-sysext.service are both only ordered Before=sysinit.target with no
  # ordering between them, and the former's ConditionDirectoryNotEmpty is
  # evaluated before the merge — so it would race, and usually lose. A unit wanted
  # by multi-user.target runs well after the merge instead.
  #
  # A sysext cannot write /etc, but systemd honours .wants/ symlinks under
  # /usr/lib/systemd/system, so the unit can ship enabled.
  mkdir -p "${STAGE}/usr/lib/systemd/system/multi-user.target.wants" \
           "${STAGE}/usr/lib/nvidia-legacy"

  cat > "${STAGE}/usr/lib/nvidia-legacy/load-nvidia.sh" <<'SHEOF'
#!/bin/sh
# Load the NVIDIA modules and create the device nodes, unless every NVIDIA GPU in
# the box is isolated for VM passthrough.
#
# TrueNAS applies isolation from the initramfs (it writes the PCI IDs into
# /etc/modprobe.d/vfio.conf, /etc/modprobe.d/nvidia.conf, /etc/modules and
# /etc/initramfs-tools/modules), so by the time this runs vfio-pci has long since
# claimed the isolated devices and cannot lose them to us. All we have to do is
# not fail the unit when there is nothing left for the host to drive.
set -eu

for dev in /sys/bus/pci/devices/*; do
    [ -r "$dev/vendor" ] || continue
    [ "$(cat "$dev/vendor")" = 0x10de ] || continue
    case "$(cat "$dev/class")" in 0x03*) ;; *) continue ;; esac

    driver=
    if [ -e "$dev/driver" ]; then
        driver=$(basename "$(readlink -f "$dev/driver")")
    fi
    if [ "$driver" = vfio-pci ]; then
        continue
    fi

    # nvidia-modprobe goes through modprobe(8), so /etc/modprobe.d still applies.
    # -m loads nvidia-modeset (required by the Vulkan ICD), -u loads nvidia-uvm
    # (CUDA), -c 0 creates /dev/nvidiactl and /dev/nvidia0.
    exec nvidia-modprobe -m -u -c 0
done

echo "no host-owned NVIDIA GPU (all isolated for VM passthrough?) - nothing to load"
SHEOF
  chmod 0755 "${STAGE}/usr/lib/nvidia-legacy/load-nvidia.sh"

  cat > "${STAGE}/usr/lib/systemd/system/nvidia-legacy-modules.service" <<'UNITEOF'
[Unit]
Description=Load NVIDIA kernel modules and create device nodes
Documentation=https://github.com/libf-de/truenas-nvidia-legacy
After=systemd-sysext.service local-fs.target
ConditionPathExists=/usr/bin/nvidia-modprobe

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/nvidia-legacy/load-nvidia.sh

[Install]
WantedBy=multi-user.target
UNITEOF
  chmod 0644 "${STAGE}/usr/lib/systemd/system/nvidia-legacy-modules.service"

  ln -sf ../nvidia-legacy-modules.service \
    "${STAGE}/usr/lib/systemd/system/multi-user.target.wants/nvidia-legacy-modules.service"

  # Keep the stock extension-release if it already matches any host ID.
  REL="${STAGE}/usr/lib/extension-release.d/extension-release.nvidia"
  if ! grep -qx 'ID=_any' "${REL}" 2>/dev/null; then
    mkdir -p "$(dirname "${REL}")"
    cat > "${REL}" <<RELEOF
ID=_any
EXTENSION_RELOAD_MANAGER=1
RELEOF
  fi
  cat "${REL}"
EOF

# Sanity-check the staged tree before packing: container toolkit present, our
# modules are the proprietary flavour, nothing else left behind.
RUN <<EOF
  # dockerd looks these up in $PATH, so they have to sit in /usr/bin — not just
  # somewhere under /stage. nvidia-container-runtime-hook is the one dockerd
  # execs per GPU container; without it every `--gpus` run dies with
  # `exec: "nvidia-container-runtime-hook": executable file not found in $PATH`.
  for b in nvidia-container-runtime-hook nvidia-container-runtime \
           nvidia-ctk nvidia-container-cli; do
    test -x "/stage/usr/bin/${b}" \
      || { echo "ERROR: /usr/bin/${b} missing from the staged tree" >&2; exit 1; }
  done
  test -n "$(find /stage/usr -name 'libnvidia-container.so.1*' -print -quit)" \
    || { echo "ERROR: libnvidia-container.so.1 missing from the staged tree" >&2; exit 1; }
  ls -l /stage/usr/bin/nvidia-container*

  KO="$(find /stage/usr/lib/modules -name 'nvidia.ko' | head -1 || true)"
  test -n "${KO}"
  # proprietary flavour reports license NVIDIA; the open modules are Dual MIT/GPL
  test "$(modinfo -F license "${KO}")" = "NVIDIA"
  modinfo -F vermagic "${KO}" | grep -q "^${KERNEL_RELEASE} "

  # every module in the output must be one we just built
  diff <(cd /build/nv/kernel && ls *.ko | sort) \
       <(find /stage/usr/lib/modules -name '*.ko*' -printf '%f\n' | sort)

  # Every path our shipped modules.dep names has to exist under the same
  # /usr/lib/modules/<release> we ship — otherwise modprobe reports
  # "module not found" for a module that is right there on disk.
  MODBASE="/stage/usr/lib/modules/${KERNEL_RELEASE}"
  test -f "${MODBASE}/modules.dep"
  for m in $(cd /build/nv/kernel && ls *.ko); do
    LINE="$(grep -m1 -E "(^|/)${m}:" "${MODBASE}/modules.dep" || true)"
    test -n "${LINE}" \
      || { echo "ERROR: ${m} has no modules.dep entry" >&2; exit 1; }
    P="${LINE%%:*}"
    test -f "${MODBASE}/${P}" \
      || { echo "ERROR: modules.dep points at ${P}, which is not in the tree" >&2; exit 1; }
    echo "  modules.dep -> ${P}"
  done

  # Vulkan: the ICD manifest, the ICD itself under its SONAME, and the SPIR-V
  # compiler it feeds shaders to. Missing any one of them means the engine's
  # device enumeration comes up empty at runtime, with no useful error.
  ICD=/stage/usr/share/vulkan/icd.d/nvidia_icd.json
  test -f "${ICD}" || { echo "ERROR: ${ICD} missing" >&2; exit 1; }
  grep -q 'libGLX_nvidia.so.0' "${ICD}" \
    || { echo "ERROR: ${ICD} does not point at libGLX_nvidia.so.0" >&2; cat "${ICD}"; exit 1; }
  for so in libGLX_nvidia.so.0 libnvidia-glcore.so."${NVIDIA_DRIVER_VERSION}" \
            libnvidia-glvkspirv.so."${NVIDIA_DRIVER_VERSION}" \
            libnvidia-glsi.so."${NVIDIA_DRIVER_VERSION}" \
            libnvidia-tls.so."${NVIDIA_DRIVER_VERSION}" \
            libnvidia-eglcore.so."${NVIDIA_DRIVER_VERSION}"; do
    test -n "$(find /stage/usr -name "${so}" -print -quit)" \
      || { echo "ERROR: ${so} missing from the staged tree" >&2; exit 1; }
  done
  # ld.so only finds these if they sit somewhere ldconfig already scans — a
  # sysext cannot add an /etc/ld.so.conf.d entry — and libnvidia-container
  # resolves what to bind-mount into a container out of the host ldcache, so a
  # library outside it is invisible to the container even though it is on disk.
  ICDDIR="$(find /stage/usr -name 'libGLX_nvidia.so.0' -printf '%h\n' | head -1 || true)"
  echo "Vulkan ICD directory: ${ICDDIR#/stage}"
  case "${ICDDIR}" in
    /stage/usr/lib|/stage/usr/lib/x86_64-linux-gnu) ;;
    *) echo "ERROR: ${ICDDIR#/stage} is not on the default ldconfig search path" >&2
       exit 1 ;;
  esac

  # Device nodes / module autoload.
  test -x /stage/usr/bin/nvidia-modprobe
  test -x /stage/usr/lib/nvidia-legacy/load-nvidia.sh
  sh -n /stage/usr/lib/nvidia-legacy/load-nvidia.sh
  test -f /stage/usr/lib/systemd/system/nvidia-legacy-modules.service
  test -L /stage/usr/lib/systemd/system/multi-user.target.wants/nvidia-legacy-modules.service
EOF

RUN mksquashfs /stage /build/nvidia.raw -all-root -noappend -comp zstd

# default command: stream the artifact to stdout
CMD ["cat", "/build/nvidia.raw"]
