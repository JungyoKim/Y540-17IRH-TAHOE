# Sources

## src/nullmoth

Changes to NullMoth 1.13.0 (tag v1.13.0, commit 0960b2ef5dbc4a573056d4c8e042a5bd2e15d651 of
https://github.com/nullmoth/nvidia-macos-driver):

- `nvaccel-y540-vs-nullmoth-1.13.0.patch`: NVAccel (kexts/NVAccel); build with `accel_build.sh`.
- `nvrmfb-y540-vs-nullmoth-1.13.0.patch`: NVRMFB (kexts/NVRMFB); build with `build_nvrmfb.sh`.
- `nvmtl-plugin-y540-vs-nullmoth-1.13.0.patch`: the Metal plug-in (plugin/); build with NullMoth's
  `RELEASE=1 build/build_plugin.sh`.
- `nvrm-binpatch.py`: NVRM is NullMoth's binary plus three byte patches (boot takeover poll, 8x faster zero-fill).
  `python3 nvrm-binpatch.py <pkgroot NVRM> NVRM` reproduces `macos/overlay/.../NVRM` byte for byte below the code
  signature; re-sign with `codesign -f -s -`.

`libvulkan_nouveau.dylib` (/dev/random fallback for sandboxed processes) and `libnvdec_h264_t2d.dylib` (faster detile)
are binary-patched NullMoth libraries; the plug-in patch describes both changes. The build scripts expect NullMoth's
build environment (Xcode, NVIDIA open-gpu-kernel-modules 610.57.04); paths inside them point at the reference machine.

## src/continuity

`btsingle.c` and `sdhook.m`, built with `build.sh` into `macos/continuity/` (x86_64, ad hoc signed).

