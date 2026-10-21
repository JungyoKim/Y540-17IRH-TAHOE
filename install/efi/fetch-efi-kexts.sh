#!/bin/bash
# fetch-efi-kexts.sh [EFI_DIR] -- put the three OCLP Modern Wireless kexts (Apple binaries, not shipped in this repository)
# into EFI/OC/Kexts. Needed before the first boot with a Broadcom BCM94352Z / DW1560; config.plist expects them.
# Works on macOS and Linux (curl, unzip, shasum or sha256sum). Source: dortania/OpenCore-Legacy-Patcher tag 3.0.0-rc.3.
set -euo pipefail
EFI=${1:-$(cd "$(dirname "$0")/../.." && pwd)/EFI}
K="$EFI/OC/Kexts"; [ -d "$K" ] || { echo "no $K"; exit 1; }
U=https://raw.githubusercontent.com/dortania/OpenCore-Legacy-Patcher/3.0.0-rc.3/payloads/Kexts/Wifi
T=$(mktemp -d)
sha(){ if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -c1-64; }
while read -r zip sum kext; do
  curl -fsSL -o "$T/$zip" "$U/$zip"
  [ "$(sha "$T/$zip")" = "$sum" ] || { echo "FAIL: $zip checksum"; exit 1; }
  (cd "$T" && unzip -q -o "$zip" -x '__MACOSX/*')
  rm -rf "$K/$kext"; cp -R "$T/$kext" "$K/$kext"; echo "ok  $kext"
done <<'EOF'
IOSkywalkFamily-v1.2.0.zip 1e12b7ef42f55b39ea54ada97b46331220668b2c48a28656e9875c5145fe2479 IOSkywalkFamily.kext
IO80211FamilyLegacy-v1.0.0.zip e681dcc76a2cd2cea4b0ad5f27a3c816055fde3cdccd890dd10a3e2c84e96d93 IO80211FamilyLegacy.kext
AirPortBrcmNIC-Tahoe-v1.0.0.zip 04edd7127ce096f5de9f8112af6d06744f27e5bc659e3d6516408755cb9af032 AirPortBrcmNIC-Tahoe.kext
EOF
rm -rf "$T"
