#!/bin/bash
# y540-install.sh <stage> [PAYLOADS | boost-mode]
# Lenovo Legion Y540-17IRH (i7-9750HF + GTX 1660 Ti) on macOS 26.7.1 Tahoe (25G241).
#
# Puts this repository's driver build, boot scripts and system-volume patches on a clean macOS 26.7.1 that already
# boots with this repository's EFI. Run the stages in order and reboot where it says so:
#   1  NullMoth NVIDIA driver 1.13.0, the Y540 driver build on top, boot scripts, settings          -> reboot
#      (if macOS asks to allow the NullMoth extensions in System Settings > Privacy & Security: allow, reboot again)
#   2  system volume: AppleHDA (sound), NullMothGPU (GPU bundles for sandboxed apps such as Safari),
#      NullMoth NVDEC video decoder, kernel collections, new boot snapshot                             -> reboot
#   3  checks + boot daemons: double-buffered scan-out with VBL lock, CPU boost mode boost|guard|off (default boost)
#   4  Broadcom BCM94352Z / DW1560 only: Wi-Fi frameworks, single-slot BLE advertising, AirDrop hook  -> reboot
# PAYLOADS (stages 1, 2, 4) defaults to <repo>/payloads, made by install/fetch.sh.
# Log: /Library/NullMoth/y540-install.log
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
STAGE=${1:-}; ARG2=${2:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
M=$HERE/macos
P=$HERE/payloads; case "$STAGE" in 1|2|4) [ -n "$ARG2" ] && P=$ARG2;; esac
mkdir -p /Library/NullMoth
LOG=/Library/NullMoth/y540-install.log
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%F %T') y540-install stage $STAGE (repository $HERE)"
die(){ echo "FAIL: $*"; exit 1; }
ok(){ echo "OK: $*"; }
[ "$(sw_vers -buildVersion)" = 25G241 ] || die "this Mac runs $(sw_vers -buildVersion); everything here is built and tested for macOS 26.7.1 (25G241)"
SKC=/System/Library/KernelCollections; AUX=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
sysvol(){ local s; s=$(diskutil info -plist / | plutil -extract DeviceIdentifier raw -o - -); case "$s" in disk*s*s*) echo "${s%s*}";; *) return 1;; esac; }
aux_build(){ # $1 boot KC, $2 system KC, $3 output: auxiliary collection with the four NullMoth kexts from /Library/Extensions
  local KARG=(--allow-missing-kdk) n
  [ -f /System/Library/Kernels/kernel ] && KARG+=(--kernel /System/Library/Kernels/kernel)
  rm -f "$3"
  kmutil create -n aux --volume-root / "${KARG[@]}" -B "$1" -S "$2" --repository /Library/Extensions -A "$3" -z > /Library/NullMoth/y540-aux.log 2>&1 || { tail -20 /Library/NullMoth/y540-aux.log; return 1; }
  n=$(kmutil inspect -a x86_64 -A "$3" 2>/dev/null | grep -oE 'com\.nullmoth\.[A-Za-z0-9]+' | sort -u | wc -l | tr -d ' ')
  [ "$n" = 4 ] || { echo "auxiliary collection has $n NullMoth kexts, expected 4"; return 1; }
}
GPUFILES="NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver NVMTLDriver.bundle/Contents/MacOS/libnvdec_h264_t2d.dylib nvmtl/libvulkan_nouveau.dylib nvmtl-allow.txt"

stage1(){
  local k f
  [ -f "$P/nullmoth/pkgroot/install.sh" ] || die "no NullMoth package at $P/nullmoth/pkgroot (run install/fetch.sh first)"
  (cd "$HERE" && shasum -a 256 -c docs/SHA256SUMS.txt >/dev/null) || die "repository files differ from docs/SHA256SUMS.txt (clone the repository again)"
  echo "--- 1/5 NullMoth NVIDIA driver 1.13.0 (upstream package)"
  (cd "$P/nullmoth/pkgroot" && bash ./install.sh); echo "(NullMoth install.sh exit $?)"
  for k in NVRM NVAccel NVRMFB NVRMAGDC; do [ -d /Library/Extensions/$k.kext ] || die "NullMoth did not install $k.kext"; done
  [ -d /Users/Shared/nvfw/nvidia ] || die "NullMoth did not install the GSP firmware in /Users/Shared/nvfw"
  echo "--- 2/5 Y540 driver build on top: NVRM, NVAccel, NVRMFB, Metal plug-in, Vulkan, H.264 decoder"
  for k in NVRM NVAccel NVRMFB; do rm -rf /Library/Extensions/$k.kext && ditto "$M/overlay/Library/Extensions/$k.kext" /Library/Extensions/$k.kext || die "copy $k"; done
  rm -rf /Library/NullMoth/kexts && ditto "$M/overlay/Library/NullMoth/kexts" /Library/NullMoth/kexts || die "copy the per-macOS NVAccel builds"
  for f in $GPUFILES; do cp -f "$M/overlay/Library/GPUBundles/$f" "/Library/GPUBundles/$f" || die "copy $f"; done
  chown -R root:wheel /Library/Extensions/NVRM.kext /Library/Extensions/NVAccel.kext /Library/Extensions/NVRMFB.kext /Library/NullMoth/kexts /Library/GPUBundles
  chmod -R 755 /Library/Extensions/NVRM.kext /Library/Extensions/NVAccel.kext /Library/Extensions/NVRMFB.kext
  chmod -R go-w /Library/NullMoth/kexts /Library/GPUBundles; chmod -R a+rX /Library/GPUBundles; chmod 644 /Library/GPUBundles/nvmtl-allow.txt
  sudo -u _windowserver /bin/test -r /Library/GPUBundles/nvmtl-allow.txt || die "WindowServer cannot read /Library/GPUBundles/nvmtl-allow.txt"
  for f in $GPUFILES; do cmp -s "$M/overlay/Library/GPUBundles/$f" "/Library/GPUBundles/$f" || die "verify $f"; done
  aux_build $SKC/BootKernelExtensions.kc $SKC/SystemKernelExtensions.kc "$AUX.y540-new" || die "auxiliary kernel collection"
  mv -f "$AUX.y540-new" "$AUX" || die "publish the auxiliary kernel collection"; ok "auxiliary kernel collection with the Y540 driver build"
  echo "--- 3/5 boot scripts and daemons (loaded in stage 3), material for stages 2 and 4"
  for f in dbuf-boot.sh eet-boot.sh eet-guard.sh dbuf-mode zflip-mode vblphase-mode vblspin-us; do cp -f "$M/nullmoth/$f" /Library/NullMoth/ || die "copy $f"; done
  mkdir -p /Library/NullMoth/daemons /Library/NullMoth/btmadv /Library/NullMoth/video /Library/NullMoth/wstrace
  cp -f "$M"/nullmoth/daemons/*.plist /Library/NullMoth/daemons/ || die "copy daemons"
  cp -f "$M"/continuity/btsingle.dylib "$M"/continuity/sdhook.dylib /Library/NullMoth/btmadv/ || die "copy continuity dylibs"
  rm -rf /Library/NullMoth/video/NullMothNVDEC.bundle; ditto "$M/video/NullMothNVDEC.bundle" /Library/NullMoth/video/NullMothNVDEC.bundle || die "copy NVDEC plug-in"
  cp -f "$HERE"/install/syspatch/*.sh /Library/NullMoth/ || die "copy system-volume scripts"
  chown -R root:wheel /Library/NullMoth; chmod 755 /Library/NullMoth/*.sh; chmod 777 /Library/NullMoth/wstrace
  echo "--- 4/5 settings: no automatic macOS updates (an update replaces the patched system volume), sleep timers"
  defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
  defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
  defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true
  defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
  pmset -a sleep 1 displaysleep 10 standby 0 hibernatemode 0 powernap 0
  echo "--- 5/5"
  ok "stage 1 done -- reboot. If macOS asks to allow the NullMoth extensions (System Settings > Privacy & Security), allow them and reboot again. Then run stage 2."
}

stage2(){
  local n DEV NAME MNT BK D NB NS VP K=$P/KDK_26.7.1_25G241.kdk H=$P/AppleHDA.kext V=/Library/NullMoth/video/NullMothNVDEC.bundle
  n=$(kmutil showloaded --list-only 2>/dev/null | grep -c com.nullmoth); echo "loaded NullMoth kexts: $n"
  [ "$n" -ge 4 ] || die "the NullMoth driver is not running: allow the extensions in System Settings > Privacy & Security and reboot"
  [ -f "$K/System/Library/Extensions/IOAudioFamily.kext/Contents/MacOS/IOAudioFamily" ] || die "KDK missing at $K (run install/fetch.sh)"
  [ -f "$H/Contents/MacOS/AppleHDA" ] || die "AppleHDA missing at $H (run install/fetch.sh)"
  [ -f "$V/Contents/MacOS/NullMothNVDEC" ] || die "no NVDEC plug-in in /Library/NullMoth/video (run stage 1 first)"
  for f in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt; do [ -e "/Library/GPUBundles/$f" ] || die "missing /Library/GPUBundles/$f"; done
  chown -R root:wheel "$K" "$H"; chmod -R go-w "$H"
  DEV=$(sysvol) || die "cannot find the booted system volume"
  NAME=$(diskutil info -plist / | plutil -extract VolumeName raw -o - -)
  [ "$(diskutil info -plist $DEV | plutil -extract VolumeName raw -o - -)" = "$NAME" ] || die "$DEV is not the booted system volume ($NAME)"
  echo "system volume $DEV ($NAME)"
  MNT=/System/Volumes/Update/mnt1; BK=/Library/NullMoth/sysvol-backup/stage2-$(date +%Y%m%d-%H%M%S)
  mount | grep -q " on $MNT " && umount "$MNT"; mkdir -p "$MNT" "$BK"
  mount -o nobrowse -t apfs /dev/$DEV "$MNT" || die "mount $DEV writable (SIP must allow it: csr-active-config 430A0000)"
  fail2(){ umount "$MNT" 2>/dev/null; die "$*"; }
  cp -p "$MNT"/System/Library/KernelCollections/*.kc "$BK"/; cp -p "$AUX" "$BK"/AuxiliaryKernelExtensions.kc.pre
  echo "--- AppleHDA: KDK extensions + AppleHDA.kext 600.2"
  rsync -r -a "$K/System/Library/Extensions/" "$MNT/System/Library/Extensions" > /Library/NullMoth/hda-rsync.log || fail2 "copy the KDK extensions"
  rsync -r -a "$H" "$MNT/System/Library/Extensions/" || fail2 "copy AppleHDA"
  chown -R root:wheel "$MNT/System/Library/Extensions/AppleHDA.kext"
  echo "--- NullMothGPU: system copy of the GPU bundles (Safari's GPU process and other sandboxed apps load from here)"
  D="$MNT/System/Library/Extensions/NullMothGPU"; rm -rf "$D.new"; mkdir -p "$D.new"
  for f in NVMTLDriver.bundle NVIDIAShared.bundle nvmtl nvmtl-allow.txt; do ditto "/Library/GPUBundles/$f" "$D.new/$f" || fail2 "copy $f"; done
  chown -R root:wheel "$D.new"; chmod -R go-w,a+rX "$D.new"; rm -rf "$D"; mv "$D.new" "$D" || fail2 "publish NullMothGPU"
  echo "--- NullMoth NVDEC: system video decoder plug-in (hardware H.264/HEVC for VideoToolbox, Safari, QuickTime)"
  VP="$MNT/System/Library/Video/Plug-Ins/NullMothNVDEC.bundle"; rm -rf "$VP"; ditto "$V" "$VP" || fail2 "copy NVDEC"
  chown -R root:wheel "$VP"; chmod -R go-w,a+rX "$VP"
  echo "--- kernel collections"
  kmutil create --volume-root "$MNT" --update-all --allow-missing-kdk > /Library/NullMoth/hda-kmutil.log 2>&1 || { tail -30 /Library/NullMoth/hda-kmutil.log; fail2 kmutil; }
  NB="$MNT$SKC/BootKernelExtensions.kc"; NS="$MNT$SKC/SystemKernelExtensions.kc"
  kmutil inspect -a x86_64 -B "$NB" -S "$NS" 2>/dev/null | grep -iE "AppleHDA|IOAudioFamily" || fail2 "AppleHDA is not in the new collections"
  aux_build "$NB" "$NS" "$AUX.y540-new" || fail2 "auxiliary collection against the new collections"
  bless --mount "$MNT" --bootefi --create-snapshot || fail2 bless
  mv -f "$AUX.y540-new" "$AUX" || fail2 "publish the auxiliary collection"
  umount "$MNT"
  diskutil apfs listSnapshots $DEV | head -12
  ok "stage 2 done -- reboot, then run stage 3"
}

stage3(){
  local mode=${ARG2:-boost} p q
  case "$mode" in boost) p=com.nullmoth.y540-eet;; guard) p=com.nullmoth.y540-eetguard;; off) p="";; *) die "boost mode must be boost, guard or off";; esac
  [ "$(kmutil showloaded --list-only 2>/dev/null | grep -c com.nullmoth)" -ge 4 ] && ok "NullMoth driver loaded" || echo "WARN: NullMoth driver not loaded"
  kextstat 2>/dev/null | grep -q AppleHDA && ok "AppleHDA loaded" || echo "WARN: AppleHDA not loaded (stage 2 done and rebooted?)"
  [ -f /System/Library/Extensions/NullMothGPU/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver ] && ok "NullMothGPU in the running system" || echo "WARN: no NullMothGPU in the running system"
  echo "--- boot daemon: double-buffered scan-out, direct scan-out, VBL locked to the panel"
  cp /Library/NullMoth/daemons/com.nullmoth.y540-dbuf.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/com.nullmoth.y540-dbuf.plist && chmod 644 /Library/LaunchDaemons/com.nullmoth.y540-dbuf.plist
  launchctl load -w /Library/LaunchDaemons/com.nullmoth.y540-dbuf.plist
  echo "--- CPU boost: $mode (boost = Energy Efficient Turbo off for good, guard = only below 78 C, off = stock 3.7 GHz)"
  for q in com.nullmoth.y540-eet com.nullmoth.y540-eetguard; do
    [ "$q" = "$p" ] && continue
    [ -f /Library/LaunchDaemons/$q.plist ] && { launchctl unload -w /Library/LaunchDaemons/$q.plist 2>/dev/null; rm -f /Library/LaunchDaemons/$q.plist; }
  done
  if [ -n "$p" ]; then
    cp /Library/NullMoth/daemons/$p.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/$p.plist && chmod 644 /Library/LaunchDaemons/$p.plist
    launchctl load -w /Library/LaunchDaemons/$p.plist
  else sysctl -w debug.nvaccel_eet_disable=0 >/dev/null 2>&1; fi
  sleep 8
  sysctl debug.nvaccel_iop_dbuf debug.nvaccel_zflip debug.nvrmfb_vbl_phase debug.nvrmfb_vbl_spin_us debug.nvaccel_eet_disable 2>&1
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|Metal|Resolution'
  ok "stage 3 done. With a BCM94352Z card run stage 4; otherwise run install/verify.sh."
}

stage4(){
  local W=$P/wifi-13.7.2-25 f
  system_profiler SPAirPortDataType 2>/dev/null | grep -qi 'Card Type: Wi-Fi *(0x14E4' || die "no Broadcom Wi-Fi card found (stage 4 is for BCM94352Z / DW1560)"
  [ -f "$W/usr/libexec/wifip2pd" ] || die "no OCLP Wi-Fi files at $W (run install/fetch.sh without --no-broadcom)"
  [ -f /System/Library/Extensions/AppleHDA.kext/Contents/MacOS/AppleHDA ] || die "run stage 2 (and reboot) first"
  for f in wifi-syspatch.sh bt-syspatch.sh sd-syspatch.sh; do [ -x /Library/NullMoth/$f ] || die "no /Library/NullMoth/$f (run stage 1 first)"; done
  echo "--- Wi-Fi: OCLP Modern Wireless Common (wifip2pd, IO80211, WiFiPeerToPeer from macOS 13.7.2)"
  bash /Library/NullMoth/wifi-syspatch.sh "$W"; grep -q PATCH-OK /Library/NullMoth/wifi-syspatch.log || die "wifi-syspatch (see /Library/NullMoth/wifi-syspatch.log)"
  launchctl enable system/com.apple.wifip2pd
  echo "--- Bluetooth: single-instance LE advertising for BCM20702 (bluetoothd + btsingle.dylib)"
  bash /Library/NullMoth/bt-syspatch.sh; grep -q PATCH-OK /Library/NullMoth/bt-syspatch.log || die "bt-syspatch (see /Library/NullMoth/bt-syspatch.log)"
  defaults write /Library/Preferences/com.apple.bluetooth NCSecondaryAdvInstance -int 0
  echo "--- AirDrop: same-account devices marked MyiCloud in sharingd (sdhook.dylib)"
  bash /Library/NullMoth/sd-syspatch.sh; grep -q PATCH-OK /Library/NullMoth/sd-syspatch.log || die "sd-syspatch (see /Library/NullMoth/sd-syspatch.log)"
  ok "stage 4 done -- reboot. Then turn AirPlay Receiver off (System Settings > General > AirDrop & Handoff) so AirDrop keeps the one advertising slot, and run install/verify.sh."
}

case "$STAGE" in 1) stage1;; 2) stage2;; 3) stage3;; 4) stage4;; *) die "usage: sudo bash install/y540-install.sh 1|2|3|4 [payloads | boost|guard|off]";; esac
