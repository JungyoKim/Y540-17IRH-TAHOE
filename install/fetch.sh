#!/bin/bash
# fetch.sh [--no-broadcom] [DEST]
# Downloads the third-party payloads this distribution installs but does not ship, checks every SHA-256 against the
# value pinned below, and unpacks the parts the installer uses. Run it on the Y540 under macOS 26.7.1 (25G241), as a
# normal user, from the repository checkout. About 3.2 GB of downloads and 6 GB of free space while unpacking.
#
#   payloads/nullmoth/pkgroot          NullMoth NVIDIA driver 1.13.0 package (driver, firmware, installer)
#   payloads/KDK_26.7.1_25G241.kdk     Kernel Debug Kit for this exact build (audio kexts merged into the system volume)
#   payloads/AppleHDA.kext             AppleHDA 600.2 from the macOS 26.0 beta KDK (Tahoe ships without it)
#   payloads/wifi-13.7.2-25            OCLP "Modern Wireless Common" files (Broadcom Wi-Fi on Tahoe; skipped with --no-broadcom)
set -euo pipefail
BROADCOM=1
if [ "${1:-}" = --no-broadcom ]; then BROADCOM=0; shift; fi
HERE=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-$HERE/payloads}
mkdir -p "$DEST"; cd "$DEST"; DEST=$(pwd)
die(){ echo "FAIL: $*" >&2; exit 1; }
sha(){ shasum -a 256 "$1" | cut -c1-64; }
get(){ # url file sha256
  local u=$1 f=$2 s=$3
  if [ -f "$f" ] && [ "$(sha "$f")" = "$s" ]; then echo "ok    $f (already here)"; return 0; fi
  echo "get   $f"
  curl -fL --retry 3 --retry-delay 5 -o "$f.part" "$u" || die "download $f"
  mv -f "$f.part" "$f"
  [ "$(sha "$f")" = "$s" ] || die "$f: SHA-256 does not match $s"
  echo "ok    $f"
}
attach(){ # dmg [passphrase] -> mount point on stdout
  local out
  if [ -n "${2:-}" ]; then out=$(printf '%s' "$2" | hdiutil attach -stdinpass -nobrowse -readonly -noverify "$1")
  else out=$(hdiutil attach -nobrowse -readonly -noverify "$1"); fi
  printf '%s\n' "$out" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1
}
kdk_expand(){ # dmg workdir -> path of the KDK contents (System/Library/Extensions ...) inside the expanded package
  local m p
  m=$(attach "$1"); [ -d "$m" ] || die "attach $1"
  p=$(find "$m" -maxdepth 2 -name '*.pkg' | head -1); [ -n "$p" ] || { hdiutil detach "$m" -quiet; die "no package in $1"; }
  rm -rf "$2"; pkgutil --expand-full "$p" "$2" >/dev/null || { hdiutil detach "$m" -quiet; die "expand $p"; }
  hdiutil detach "$m" -quiet || true
  [ -d "$2/KDK.pkg/Payload/System/Library/Extensions" ] || die "no KDK.pkg/Payload/System/Library/Extensions in $1"
  echo "$2/KDK.pkg/Payload"
}

GH=https://github.com
get $GH/nullmoth/nvidia-macos-driver/releases/download/v1.13.0/nullmoth-nvidia-1.13.0.tar.gz \
    nullmoth-nvidia-1.13.0.tar.gz 994970b1bba53e3ae8d7f500ef27b25cae8bc6818abc112d35230a58e6882fdf
get $GH/dortania/KdkSupportPkg/releases/download/25G241/Kernel_Debug_Kit_26.7.1_build_25G241.dmg \
    Kernel_Debug_Kit_26.7.1_build_25G241.dmg 9045a521c8ae362d4cb2cc54701b03462686e0069518a0b66cfe2028f87dfe9b
get $GH/dortania/KdkSupportPkg/releases/download/25A5279m/Kernel_Debug_Kit_26.0_build_25A5279m.dmg \
    Kernel_Debug_Kit_26.0_build_25A5279m.dmg eb2e2b7dd534282c45c2d295e8b9a68f82cc6e5d52984949ca9be0685ca90cb1
[ $BROADCOM = 0 ] || get $GH/dortania/PatcherSupportPkg/releases/download/2.0.2/Universal-Binaries.dmg \
    Universal-Binaries.dmg edd4fabc16ba58bfc63de0b9ca0c2bab7de4830a3bde4c55ff09ffd4141d0b6c

echo "--- NullMoth 1.13.0 package"
if [ ! -f nullmoth/pkgroot/install.sh ]; then
  rm -rf nullmoth; mkdir nullmoth
  tar -xzf nullmoth-nvidia-1.13.0.tar.gz -C nullmoth || die "unpack NullMoth"
fi
(cd nullmoth/pkgroot && shasum -a 256 -c SHA256SUMS >/dev/null) || die "NullMoth package files do not match its SHA256SUMS"
echo "ok    nullmoth/pkgroot"

echo "--- KDK 26.7.1 (25G241)"
if [ ! -f KDK_26.7.1_25G241.kdk/System/Library/Extensions/IOAudioFamily.kext/Contents/MacOS/IOAudioFamily ]; then
  K=$(kdk_expand Kernel_Debug_Kit_26.7.1_build_25G241.dmg "$DEST/x-kdk2671")
  [ -n "$K" ] && [ -d "$K/System/Library/Extensions" ] || die "no KDK folder in the 26.7.1 package"
  rm -rf KDK_26.7.1_25G241.kdk; mv "$K" KDK_26.7.1_25G241.kdk; rm -rf x-kdk2671
fi
echo "ok    KDK_26.7.1_25G241.kdk ($(ls KDK_26.7.1_25G241.kdk/System/Library/Extensions | wc -l | tr -d ' ') extensions)"

echo "--- AppleHDA 600.2 from KDK 26.0 (25A5279m)"
HDA_SHA=6bf19c385a1212160be8a01fd7903aaa0416407e0b52e949f49d04cee4c65de7
if [ ! -f AppleHDA.kext/Contents/MacOS/AppleHDA ] || [ "$(sha AppleHDA.kext/Contents/MacOS/AppleHDA)" != $HDA_SHA ]; then
  K=$(kdk_expand Kernel_Debug_Kit_26.0_build_25A5279m.dmg "$DEST/x-kdk260")
  [ -n "$K" ] && [ -f "$K/System/Library/Extensions/AppleHDA.kext/Contents/MacOS/AppleHDA" ] || die "no AppleHDA in the 26.0 KDK"
  rm -rf AppleHDA.kext; ditto "$K/System/Library/Extensions/AppleHDA.kext" AppleHDA.kext; rm -rf x-kdk260
fi
[ "$(sha AppleHDA.kext/Contents/MacOS/AppleHDA)" = $HDA_SHA ] || die "AppleHDA binary differs from the tested one"
echo "ok    AppleHDA.kext"

if [ $BROADCOM = 1 ]; then
  echo "--- OCLP Modern Wireless Common (13.7.2-25)"
  if [ ! -f wifi-13.7.2-25/usr/libexec/wifip2pd ]; then
    M=$(attach Universal-Binaries.dmg password); [ -d "$M/13.7.2-25" ] || die "13.7.2-25 not in Universal-Binaries.dmg"
    rm -rf wifi-13.7.2-25; ditto "$M/13.7.2-25" wifi-13.7.2-25; hdiutil detach "$M" -quiet || true
  fi
  for f in usr/libexec/wifip2pd System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211 \
           System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer; do
    [ -e "wifi-13.7.2-25/$f" ] || die "wifi-13.7.2-25/$f missing"; done
  echo "ok    wifi-13.7.2-25"
fi
echo "PAYLOADS-OK $DEST"
echo "The .dmg/.tar.gz downloads can be deleted now; fetch.sh skips anything already unpacked."
