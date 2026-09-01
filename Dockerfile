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

# Run depmod over the merged tree (host modules + our nvidia modules) so
# the regenerated modules.dep / modules.alias / modules.symbols carry our
# additions. We then ship only the regenerated index files in the sysext.
RUN <<EOF
  STAGE=/tmp/depmod
  # locate the modules dir in the linux-image deb (older debs use /lib, newer /usr/lib)
  if [ -d "/tmp/image/usr/lib/modules/${KERNEL_RELEASE}" ]; then
    SRC="/tmp/image/usr/lib/modules/${KERNEL_RELEASE}"
  else
    SRC="/tmp/image/lib/modules/${KERNEL_RELEASE}"
  fi
  mkdir -p "${STAGE}/lib/modules/${KERNEL_RELEASE}/extra/nvidia"
  cp -a "${SRC}/." "${STAGE}/lib/modules/${KERNEL_RELEASE}/"
  cp /build/nv/kernel/*.ko "${STAGE}/lib/modules/${KERNEL_RELEASE}/extra/nvidia/"
  depmod -b "${STAGE}" "${KERNEL_RELEASE}"
  ls "${STAGE}/lib/modules/${KERNEL_RELEASE}/" | grep -E '^modules\.'
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

# Fallback path only: no stock raw to inherit from, so pull the container
# toolkit straight from NVIDIA's repo. This gets CTK but *not* the rest of the
# stock userland (libcuda &c.) — the overlay path is the better one.
RUN <<EOF
  if [ "$(cat /build/stage-mode)" != "fallback" ]; then exit 0; fi
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
  cp -a /tmp/ctk/x/usr /stage/
  rm -rf /tmp/ctk
  ls -l /stage/usr/bin
EOF

# Overlay our proprietary-flavour build onto the staging tree.
RUN <<EOF
  STAGE=/stage
  STAGEMOD="/tmp/depmod/lib/modules/${KERNEL_RELEASE}"
  mkdir -p "${STAGE}/usr/lib/modules"

  # Install into whatever directory the stock raw used for nvidia.ko; only fall
  # back to extra/nvidia when there was nothing to match (fallback path, or a
  # stock raw built for a different kernel release).
  MODDIR="$(find "${STAGE}/usr/lib/modules/${KERNEL_RELEASE}" -name 'nvidia.ko*' -printf '%h\n' 2>/dev/null | head -1 || true)"
  MODDIR="${MODDIR:-${STAGE}/usr/lib/modules/${KERNEL_RELEASE}/extra/nvidia}"

  # Drop every kernel module the stock raw shipped — those are the open-flavour
  # builds, and anything we don't overwrite must not survive into the output.
  find "${STAGE}/usr/lib/modules" \
    \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) \
    -print -delete

  mkdir -p "${MODDIR}"
  cp /build/nv/kernel/*.ko "${MODDIR}/"

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

  # libnvidia-ml / libnvidia-cfg: same idea. Replace every versioned copy the
  # stock raw carries (the version normally matches, so this is an overwrite)
  # and repoint the SONAME symlinks at ours.
  for lib in libnvidia-ml libnvidia-cfg; do
    SRC="/build/nv/${lib}.so.${NVIDIA_DRIVER_VERSION}"
    [ -f "${SRC}" ] || continue
    DIRS="$(find "${STAGE}/usr" -name "${lib}.so.*" -printf '%h\n' | sort -u)"
    DIRS="${DIRS:-${STAGE}/usr/lib/x86_64-linux-gnu}"
    for d in ${DIRS}; do
      mkdir -p "${d}"
      find "${d}" -maxdepth 1 \( -name "${lib}.so" -o -name "${lib}.so.*" \) -delete
      cp "${SRC}" "${d}/"
      ln -s "${lib}.so.${NVIDIA_DRIVER_VERSION}" "${d}/${lib}.so.1"
      ln -s "${lib}.so.1" "${d}/${lib}.so"
    done
  done

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
  CTK="$(find /stage \( -name 'nvidia-ctk' -o -name 'libnvidia-container.so.1*' \) -print -quit)"
  test -n "${CTK}" || { echo "ERROR: no container toolkit in the staged tree" >&2; exit 1; }

  KO="$(find /stage/usr/lib/modules -name 'nvidia.ko' | head -1 || true)"
  test -n "${KO}"
  # proprietary flavour reports license NVIDIA; the open modules are Dual MIT/GPL
  test "$(modinfo -F license "${KO}")" = "NVIDIA"
  modinfo -F vermagic "${KO}" | grep -q "^${KERNEL_RELEASE} "

  # every module in the output must be one we just built
  diff <(cd /build/nv/kernel && ls *.ko | sort) \
       <(find /stage/usr/lib/modules -name '*.ko*' -printf '%f\n' | sort)
EOF

RUN mksquashfs /stage /build/nvidia.raw -all-root -noappend -comp zstd

# default command: stream the artifact to stdout
CMD ["cat", "/build/nvidia.raw"]
