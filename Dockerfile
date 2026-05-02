ARG NVIDIA_DRIVER_VERSION=570.172.08
ARG KERNEL_RELEASE=6.12.33-production+truenas
ARG KERNEL_HEADERS_DIR=linux-headers-truenas-production-amd64
ARG KERNEL_HEADERS_URL=https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.0/packages/linux-headers-truenas-production-amd64_6.12.33-production+truenas-1_amd64.deb
ARG KERNEL_IMAGE_URL=https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.0/packages/linux-image-truenas-production-amd64_6.12.33-production+truenas-1_amd64.deb

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
      curl ca-certificates xz-utils squashfs-tools
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

# Lay out the sysext tree
RUN <<EOF
  ROOT=/build/sysext
  MODDIR="${ROOT}/usr/lib/modules/${KERNEL_RELEASE}/extra/nvidia"
  STAGEMOD="/tmp/depmod/lib/modules/${KERNEL_RELEASE}"
  mkdir -p "${MODDIR}" "${ROOT}/usr/bin" \
           "${ROOT}/usr/lib/x86_64-linux-gnu" \
           "${ROOT}/usr/lib/extension-release.d"

  cp /build/nv/kernel/*.ko "${MODDIR}/"

  # Ship the depmod-generated index files. modules.builtin* and modules.devname
  # depend only on the kernel image, not on our additions, so we leave the host's
  # versions in place. Everything else can change with our nvidia modules.
  for f in modules.dep modules.dep.bin \
           modules.alias modules.alias.bin \
           modules.symbols modules.symbols.bin \
           modules.softdep; do
    if [ -f "${STAGEMOD}/${f}" ]; then
      cp "${STAGEMOD}/${f}" "${ROOT}/usr/lib/modules/${KERNEL_RELEASE}/${f}"
    fi
  done

  # userland that the spinpid container (and host nvidia-smi) need
  cp /build/nv/nvidia-smi "${ROOT}/usr/bin/"
  cp /build/nv/libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} "${ROOT}/usr/lib/x86_64-linux-gnu/"
  ln -s libnvidia-ml.so.${NVIDIA_DRIVER_VERSION} "${ROOT}/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1"
  ln -s libnvidia-ml.so.1 "${ROOT}/usr/lib/x86_64-linux-gnu/libnvidia-ml.so"
  if [ -f "/build/nv/libnvidia-cfg.so.${NVIDIA_DRIVER_VERSION}" ]; then
    cp "/build/nv/libnvidia-cfg.so.${NVIDIA_DRIVER_VERSION}" "${ROOT}/usr/lib/x86_64-linux-gnu/"
    ln -s "libnvidia-cfg.so.${NVIDIA_DRIVER_VERSION}" "${ROOT}/usr/lib/x86_64-linux-gnu/libnvidia-cfg.so.1"
    ln -s libnvidia-cfg.so.1 "${ROOT}/usr/lib/x86_64-linux-gnu/libnvidia-cfg.so"
  fi

  cat > "${ROOT}/usr/lib/extension-release.d/extension-release.nvidia" <<REL
ID=_any
EXTENSION_RELOAD_MANAGER=1
REL
EOF

RUN mksquashfs /build/sysext /build/nvidia.raw -all-root -noappend -comp zstd

# default command: stream the artifact to stdout
CMD ["cat", "/build/nvidia.raw"]
