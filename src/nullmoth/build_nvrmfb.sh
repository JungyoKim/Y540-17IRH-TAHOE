#!/bin/bash
# build_nvrmfb.sh <src-root> <out>  -- Y540 local build of NVRMFB (mirrors build/accel_build.sh flags)
set -uo pipefail
ROOT=$1; OUT=$2; SRC=$ROOT/kexts/NVRMFB; mkdir -p "$OUT/NVRMFB.kext/Contents/MacOS"
OGKM=${OGKM:-$HOME/nmdev/ogkm610}
SDK=$(xcrun --show-sdk-path); KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"; NV="$OGKM/src/nvidia"; KMS="$OGKM/src/nvidia-modeset"
RMINC=( -I"$NV/arch/nvalloc/unix/include" -I"$NV/arch/nvalloc/common/inc" -I"$OGKM/src/common/sdk/nvidia/inc" -I"$OGKM/src/common/sdk/nvidia/inc/hw"
  -I"$OGKM/src/common/inc" -I"$OGKM/src/common/shared/inc" -I"$NV/inc" -I"$NV/inc/os" -I"$NV/interface" -I"$OGKM/src/common/inc/displayport" )
KMSINC=( -I"$KMS/os-interface/include" -I"$KMS/kapi/interface" -I"$KMS/kapi/include" -I"$OGKM/src/common/unix/nvidia-push/interface" -I"$KMS/interface" -I"$KMS/include"
  -I"$OGKM/src/common/unix/common/inc" -I"$OGKM/src/common/modeset" -I"$OGKM/src/common/unix/common/utils/interface" )
DEFS=( -DNVCPU_X86_64 -DNV_UNIX -DNV_KERNEL_INTERFACE_LAYER -DNVRM -DNV_VERSION_STRING='"610.57.04"' ${EXTRA_DEFS:-} )
CFLAGS=( -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR" -I"$SRC" -I"$SRC/fb" "${RMINC[@]}" "${KMSINC[@]}"
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT "${DEFS[@]}"
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -Wno-unused-variable -O2 )
xcrun clang++ "${CFLAGS[@]}" -c "$SRC/fb/nvrm-fb.cpp" -o "$OUT/nvrm-fb.o" 2>"$OUT/fb.err" || { grep -E 'error' "$OUT/fb.err" | head -15; exit 1; }
xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext "$OUT/nvrm-fb.o" -o "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB" 2>"$OUT/ld.err" || { head -15 "$OUT/ld.err"; exit 1; }
cp "$SRC/fb/Info.plist" "$OUT/NVRMFB.kext/Contents/Info.plist"
echo "BUILT NVRMFB $(stat -f %z "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB") B"
