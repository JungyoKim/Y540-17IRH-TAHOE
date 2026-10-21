#!/bin/bash
# install-efi.sh daily|installer [--dry-run]
# Copies this repository's EFI to the EFI partition of the disk macOS is running from. Keeps the Mac identity already
# there (PlatformInfo > Generic: SystemSerialNumber, MLB, SystemUUID, ROM), adds the OCLP Wi-Fi kexts, and backs the old
# EFI folder up to /Library/NullMoth/efi-backup-<date>.tgz first.
#   daily      after stage 1 (NVIDIA driver installed): firmware framebuffer blocked, full GPU BAR, no boot picker
#   installer  before the driver: firmware framebuffer allowed, small BAR, boot picker for 10 s
# --dry-run builds the new EFI in a temporary folder and lists what would change, without writing the EFI partition.
set -euo pipefail
MODE=${1:-}; DRY=0; [ "${2:-}" = --dry-run ] && DRY=1
case "$MODE" in daily) CFG=config.plist;; installer) CFG=config-installer.plist;; *) echo "usage: sudo bash install/efi/install-efi.sh daily|installer [--dry-run]"; exit 1;; esac
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")/../.." && pwd)
unmount(){ diskutil unmount "$MNT" >/dev/null 2>&1 || umount "$MNT"; }
die(){ echo "FAIL: $*"; [ -n "${MNT:-}" ] && unmount 2>/dev/null; exit 1; }
STORE=$(diskutil info -plist / | plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw -o - -) || die "no APFS physical store for /"
WHOLE=$(diskutil info -plist "$STORE" | plutil -extract ParentWholeDisk raw -o - -)
ESP=${WHOLE}s1
[ "$(diskutil info -plist $ESP | plutil -extract Content raw -o - -)" = EFI ] || die "$ESP is not an EFI partition"
echo "boot disk $WHOLE, EFI partition $ESP, mode $MODE"
ST=$(mktemp -d /tmp/y540efi.XXXX); MNT=$(mktemp -d /tmp/y540esp.XXXX)
ditto "$HERE/EFI" "$ST/EFI"
[ "$CFG" = config.plist ] || cp "$ST/EFI/OC/$CFG" "$ST/EFI/OC/config.plist"
rm -f "$ST/EFI/OC/config-installer.plist"
NEW="$ST/EFI/OC/config.plist"
mount -t msdos /dev/$ESP "$MNT" || die "mount $ESP"
OLD="$MNT/EFI/OC/config.plist"
if [ -f "$OLD" ]; then
  for k in SystemSerialNumber MLB SystemUUID; do
    v=$(plutil -extract PlatformInfo.Generic.$k raw -o - "$OLD" 2>/dev/null || true)
    [ -n "$v" ] && [ "$v" != GENERATE-ME ] && plutil -replace PlatformInfo.Generic.$k -string "$v" "$NEW"
  done
  v=$(plutil -extract PlatformInfo.Generic.ROM raw -o - "$OLD" 2>/dev/null || true)
  [ -n "$v" ] && [ "$v" != AAAAAAAA ] && plutil -replace PlatformInfo.Generic.ROM -data "$v" "$NEW"
fi
[ "$(plutil -extract PlatformInfo.Generic.SystemSerialNumber raw -o - "$NEW")" != GENERATE-ME ] || die "no Mac identity in the current EFI: set it first with install/efi/set-smbios.py (see AGENTS.md)"
if system_profiler SPAirPortDataType 2>/dev/null | grep -qi 'Card Type: Wi-Fi *(0x14E4' || [ -d "$MNT/EFI/OC/Kexts/IOSkywalkFamily.kext" ]; then
  if [ -d "$MNT/EFI/OC/Kexts/IOSkywalkFamily.kext" ] && [ -d "$MNT/EFI/OC/Kexts/IO80211FamilyLegacy.kext" ] && [ -d "$MNT/EFI/OC/Kexts/AirPortBrcmNIC-Tahoe.kext" ]; then
    for k in IOSkywalkFamily IO80211FamilyLegacy AirPortBrcmNIC-Tahoe; do ditto --norsrc --noextattr --noacl "$MNT/EFI/OC/Kexts/$k.kext" "$ST/EFI/OC/Kexts/$k.kext"; done
  else bash "$HERE/install/efi/fetch-efi-kexts.sh" "$ST/EFI" || die "OCLP Wi-Fi kexts"; fi
fi
plutil -lint "$NEW" >/dev/null || die "new config.plist does not parse"
if [ $DRY = 1 ]; then
  echo "--- dry run: differences between $ESP:/EFI and the new EFI"
  diff -rq "$MNT/EFI" "$ST/EFI" | sed "s#$MNT#ESP#g; s#$ST#NEW#g" || true
  unmount; echo "new EFI left in $ST/EFI"; exit 0
fi
mkdir -p /Library/NullMoth; B=/Library/NullMoth/efi-backup-$(date +%Y%m%d-%H%M%S).tgz
tar -czf "$B" -C "$MNT" EFI || die "backup"
echo "backup $B"
rm -rf "$MNT/EFI.new"; ditto --norsrc --noextattr --noacl "$ST/EFI" "$MNT/EFI.new" || die "copy"
rm -rf "$MNT/EFI.old"; mv "$MNT/EFI" "$MNT/EFI.old" && mv "$MNT/EFI.new" "$MNT/EFI" || die "swap (old EFI kept in EFI.old)"
rm -rf "$MNT/EFI.old"
unmount; rm -rf "$ST"
echo "OK: $MODE EFI installed on $ESP"
