ARG NVIDIA_DRIVER_VERSION=570.172.08
ARG KERNEL_RELEASE=6.12.33-production+truenas
ARG KERNEL_HEADERS_DIR=linux-headers-truenas-production-amd64
ARG KERNEL_HEADERS_URL=https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.0/packages/linux-headers-truenas-production-amd64_6.12.33-production+truenas-1_amd64.deb

FROM debian:bookworm AS builder
ARG NVIDIA_DRIVER_VERSION
ARG KERNEL_RELEASE
ARG KERNEL_HEADERS_DIR
ARG KERNEL_HEADERS_URL

SHELL ["/bin/bash", "-eux", "-o", "pipefail", "-c"]

RUN <<EOF
  apt-get -q update
  apt-get install -qy --no-install-recommends \
      build-essential kmod libelf-dev bc bison flex \
      curl ca-certificates xz-utils squashfs-tools
EOF

# Pull the TrueNAS-built kernel headers .deb directly from the TrueNAS download mirror.
RUN <<EOF
  curl -fSsL --retry 3 -o /tmp/headers.deb "${KERNEL_HEADERS_URL}"
  dpkg-deb -x /tmp/headers.deb /
  test -f "/usr/src/${KERNEL_HEADERS_DIR}/Makefile"
  rm /tmp/headers.deb
EOF

ENV KSRC=/usr/src/${KERNEL_HEADERS_DIR}

WORKDIR /build

RUN curl -fSsLO "https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"

RUN sh "NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run" --extract-only --target /build/nv

# Build kernel modules against the TrueNAS kernel
RUN <<EOF
  cd /build/nv/kernel
  make -j"$(nproc)" SYSSRC="${KSRC}" modules
  ls -l *.ko
EOF

# Lay out the sysext tree
RUN <<EOF
  ROOT=/build/sysext
  MODDIR="${ROOT}/usr/lib/modules/${KERNEL_RELEASE}/extra/nvidia"
  mkdir -p "${MODDIR}" "${ROOT}/usr/bin" \
           "${ROOT}/usr/lib/x86_64-linux-gnu" \
           "${ROOT}/usr/lib/extension-release.d"

  cp /build/nv/kernel/*.ko "${MODDIR}/"

  # userland that the spinpid container (and host nvidia-smi) need
  cp /build/nv/nvidia-smi "${ROOT}/usr/bin/"
  cp -P /build/nv/libnvidia-ml.so*           "${ROOT}/usr/lib/x86_64-linux-gnu/"
  cp -P /build/nv/libnvidia-cfg.so*          "${ROOT}/usr/lib/x86_64-linux-gnu/" || true

  cat > "${ROOT}/usr/lib/extension-release.d/extension-release.nvidia" <<REL
ID=_any
EXTENSION_RELOAD_MANAGER=1
REL
EOF

RUN mksquashfs /build/sysext /build/nvidia.raw -all-root -noappend -comp zstd

# default command: stream the artifact to stdout
CMD ["cat", "/build/nvidia.raw"]
