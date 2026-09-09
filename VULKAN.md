 ---

  1. Driver branch: must be ≥ 510, prefer 570.x legacy

  The engine requires Vulkan 1.3 — Engine_Vulkan::API_VERSION = VK_API_VERSION_1_3, and VulkanDeviceUsable() rejects any physical device reporting less. NVIDIA gained Vulkan 1.3 in the 510 branch; the 470
  legacy branch tops out at Vulkan 1.2 and the GPU engine will refuse the device even with everything else perfect.

  The 1050 Ti is Pascal, dropped in 580, so the 570.x legacy branch is both the right target and Vulkan-1.3 capable. Do not let it land on 470.

  2. Kernel modules

  - nvidia.ko — required
  - nvidia-uvm.ko — CUDA; keep for the toolkit's compute capability
  - nvidia-modeset.ko — load it at boot. Currently present on disk but never loaded, and NVIDIA's Vulkan ICD fails init without it. This is the specific thing that's broken right now.
  - nvidia-drm.ko — optional, display only

  modules.dep must actually resolve — the current install is broken there (modprobe looks for extra/nvidia/nvidia.ko, which doesn't exist even though nvidia is loaded). Either fix depmod metadata or have the
  init hook insmod the .ko files explicitly in order: nvidia, nvidia-modeset, nvidia-uvm.

  3. Device nodes, created at boot

  ┌─────────────────────────────┬───────────────┐
  │            Node             │ Major, minor  │
  ├─────────────────────────────┼───────────────┤
  │ /dev/nvidiactl              │ 195, 255      │
  ├─────────────────────────────┼───────────────┤
  │ /dev/nvidia0                │ 195, 0        │
  ├─────────────────────────────┼───────────────┤
  │ /dev/nvidia-modeset         │ 195, 254      │
  ├─────────────────────────────┼───────────────┤
  │ /dev/nvidia-uvm, -uvm-tools │ dynamic major │
  └─────────────────────────────┴───────────────┘

  Shipping the setuid nvidia-modprobe binary handles all of these automatically and is the cleaner option; otherwise mknod -m 666 them in the init hook.

  4. Userspace libraries (64-bit)

  Versioned files plus the .so.0 / .so.1 symlinks, in a directory covered by ld.so.conf, followed by ldconfig — libnvidia-container resolves what to mount via the host ldcache, so a library outside it is
  invisible to the container even if it's on disk.

  Required for Vulkan:
  - libGLX_nvidia.so.<ver> → libGLX_nvidia.so.0 — this is the Vulkan ICD
  - libnvidia-glcore.so.<ver>
  - libnvidia-glvkspirv.so.<ver> — the SPIR-V compiler; the engine feeds it 25 compiled shaders, nothing runs without it
  - libnvidia-glsi.so.<ver>
  - libnvidia-tls.so.<ver>
  - libnvidia-eglcore.so.<ver>
  - libnvidia-cfg.so.1
  
  Keep for the toolkit and for nvidia-smi (the benchmark shells out to it to record the GPU):
  - libnvidia-ml.so.<ver> → .so.1, libcuda.so.<ver> → .so.1, nvidia-smi
  
  Optional, include if the branch ships them: libnvidia-rtcore.so (no RT cores on Pascal), libnvidia-vulkan-producer.so (Wayland only).

  5. Vulkan ICD manifest

  /usr/share/vulkan/icd.d/nvidia_icd.json:

  {
      "file_format_version": "1.0.0",
      "ICD": {
          "library_path": "libGLX_nvidia.so.0",
          "api_version": "1.3.0"
      }
  }

  Nice to have but not critical — my container entrypoint writes an equivalent manifest when it finds none, which is what it's doing today. Note the host currently has only Mesa ICDs there, so nothing is being
  shadowed.
