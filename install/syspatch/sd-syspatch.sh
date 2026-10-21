#!/bin/bash
# sd-syspatch.sh -- put sdhook.dylib on the system volume and make launchd start sharingd with it, then bless.
# On this machine sharingd never learns the IDS identity of the iPhone it sees over BLE (the controller does not resolve
# its private address), so the device lacks the MyiCloud flag and rapportd's AirDrop discovery drops it. sdhook.dylib
# marks same-account (type 2) identities as MyiCloud after -[SFDevice updateWithRPIdentity:], which is what
# Sharing.framework itself does when it runs in a virtual machine. Enables Mac -> iPhone AirDrop.
LOG=/Library/NullMoth/sd-syspatch.log
exec > "$LOG" 2>&1
set -x
. "$(dirname "$0")/common.sh" 2>/dev/null || . /Library/NullMoth/common.sh
SRC=${1:-/Library/NullMoth/btmadv/sdhook.dylib}
DY=/System/Library/NullMoth/sdhook.dylib
BK=/Library/NullMoth/sysvol-backup/sd-launchd-$(date +%Y%m%d-%H%M%S)
PB=/usr/libexec/PlistBuddy
[ -f "$SRC" ] || fail "missing $SRC"
sv_mount
P1="$MNT/System/Library/LaunchAgents/com.apple.sharingd.plist"
P2="$MNT/System/Library/xpc/launchd.plist"
mkdir -p "$BK" && cp -p "$P1" "$P2" "$BK/" || fail backup
mkdir -p "$MNT/System/Library/NullMoth" && cp "$SRC" "$MNT$DY" && cmp "$SRC" "$MNT$DY" || fail "copy dylib"
chown -R root:wheel "$MNT/System/Library/NullMoth"; chmod 755 "$MNT$DY"
$PB -c "Print :EnvironmentVariables" "$P1" >/dev/null 2>&1 || $PB -c "Add :EnvironmentVariables dict" "$P1" || fail p1dict
$PB -c "Delete :EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$P1" 2>/dev/null
$PB -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string $DY" "$P1" || fail p1
K=":LaunchDaemons:/System/Library/LaunchAgents/com.apple.sharingd.plist:EnvironmentVariables"
$PB -c "Print $K" "$P2" >/dev/null 2>&1 || $PB -c "Add $K dict" "$P2" || fail p2dict
$PB -c "Delete $K:DYLD_INSERT_LIBRARIES" "$P2" 2>/dev/null
$PB -c "Add $K:DYLD_INSERT_LIBRARIES string $DY" "$P2" || fail p2
plutil -convert binary1 "$P1" && plutil -convert binary1 "$P2" || fail convert
chown root:wheel "$P1"; chown root:admin "$P2"; chmod 644 "$P1" "$P2"
plutil -lint "$P1" "$P2" || fail lint
sv_bless
echo "backup: $BK"
echo PATCH-OK
echo PATCHDONE
