#!/bin/bash
# gpu-syspatch.sh -- copy /Library/GPUBundles to the system volume (/System/Library/Extensions/NullMothGPU) and the NullMoth
# NVDEC plug-in to /System/Library/Video/Plug-Ins, then bless a new boot snapshot. Stage 2 of y540-install.sh does the same;
# run this one after changing the GPU bundles. Sandboxed processes (Safari's GPU process, QuickLook) load the driver only
# from the system volume.
LOG=/Library/NullMoth/gpu-syspatch.log
exec > "$LOG" 2>&1
set -x
. "$(dirname "$0")/common.sh" 2>/dev/null || . /Library/NullMoth/common.sh
SRC=/Library/GPUBundles
V=${1:-/Library/NullMoth/video/NullMothNVDEC.bundle}
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt; do [ -e "$SRC/$b" ] || fail "missing $SRC/$b"; done
sv_mount
T="$MNT/System/Library/Extensions/NullMothGPU"
rm -rf "$T.new"; mkdir -p "$T.new" || fail mkdir
for b in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt; do ditto "$SRC/$b" "$T.new/$b" || fail "copy $b"; done
chown -R root:wheel "$T.new"; chmod -R go-w "$T.new"; chmod -R a+rX "$T.new"
for f in NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver NVMTLDriver.bundle/Contents/MacOS/libnvdec_h264_t2d.dylib NVMTLDriver.bundle/Contents/MacOS/libnvdec_hevc.dylib nvmtl/libvulkan_nouveau.dylib; do
  cmp -s "$SRC/$f" "$T.new/$f" || fail "verify $f"; done
rm -rf "$T"; mv "$T.new" "$T" || fail publish
if [ -d "$V" ]; then
  VP="$MNT/System/Library/Video/Plug-Ins/NullMothNVDEC.bundle"
  rm -rf "$VP"; ditto "$V" "$VP" || fail "copy NVDEC"; chown -R root:wheel "$VP"; chmod -R go-w "$VP"; chmod -R a+rX "$VP"
fi
du -sh "$T"
sv_bless
echo PATCH-OK
echo PATCHDONE
