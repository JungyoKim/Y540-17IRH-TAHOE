#!/bin/bash
# wifi-syspatch.sh SRC -- OCLP 3.0.0 "Modern Wireless Common" root patch for Broadcom Wi-Fi on Tahoe, applied without OCLP.
# Same files and copy rules as OpenCore Legacy Patcher (wifip2pd overwritten, IO80211/WiFiPeerToPeer frameworks merged with
# rsync, then chmod 755 + chown root:wheel), but no kernel collection or AuxKC rebuild (no kexts change on the system volume)
# and no KextPolicy reset, which OCLP does and which would drop the NullMoth kexts. Originals are backed up first.
# SRC = the 13.7.2-25 folder of PatcherSupportPkg 2.0.2 Universal-Binaries.dmg (install/fetch.sh unpacks it).
LOG=/Library/NullMoth/wifi-syspatch.log
exec > >(tee "$LOG") 2>&1
set -x
. "$(dirname "$0")/common.sh" 2>/dev/null || . /Library/NullMoth/common.sh
SRC=${1:-}
BK=/Library/NullMoth/sysvol-backup/wifi-orig-$(date +%Y%m%d-%H%M%S)
for f in usr/libexec/wifip2pd System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211 System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer; do [ -e "$SRC/$f" ] || fail "missing $SRC/$f"; done
sv_mount
mkdir -p "$BK"
ls "$MNT/System/Library/Extensions/NullMothGPU" "$MNT/System/Library/Extensions/AppleHDA.kext/Contents/MacOS" >/dev/null || fail "NullMothGPU/AppleHDA not on the mounted volume (run stage 2 first)"
PF="$MNT/System/Library/PrivateFrameworks"
ditto "$PF/IO80211.framework" "$BK/IO80211.framework" && ditto "$PF/WiFiPeerToPeer.framework" "$BK/WiFiPeerToPeer.framework" && cp -p "$MNT/usr/libexec/wifip2pd" "$BK/wifip2pd" || fail backup
rm "$MNT/usr/libexec/wifip2pd" && cp -R "$SRC/usr/libexec/wifip2pd" "$MNT/usr/libexec/" || fail wifip2pd
chmod 755 "$MNT/usr/libexec/wifip2pd"; chown root:wheel "$MNT/usr/libexec/wifip2pd"
for fw in IO80211.framework WiFiPeerToPeer.framework; do
  /usr/bin/rsync -r -i -a "$SRC/System/Library/PrivateFrameworks/$fw" "$PF/" || fail "rsync $fw"
  chmod -Rf 755 "$PF/$fw"; chown -Rf root:wheel "$PF/$fw"
done
for f in usr/libexec/wifip2pd System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211 System/Library/PrivateFrameworks/IO80211.framework/Versions/A/IO80211Old.dylib System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeer System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/WiFiPeerToPeerOld.dylib System/Library/PrivateFrameworks/WiFiPeerToPeer.framework/Versions/A/LibSystemShim.dylib; do
  cmp -s "$SRC/$f" "$MNT/$f" || fail "verify $f"; done
sv_bless
echo "backup: $BK"
echo PATCH-OK
echo PATCHDONE
