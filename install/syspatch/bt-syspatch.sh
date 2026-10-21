#!/bin/bash
# bt-syspatch.sh -- put btsingle.dylib on the system volume and make launchd start bluetoothd with it, then bless.
# Tahoe's bluetoothd always asks the controller for Apple's multi-instance advertising (vendor command 0x148); the
# BCM20702 in a BCM94352Z / DW1560 refuses it and bluetoothd then leaves the whole LE advertising stack off (no Handoff,
# AirDrop or Find My presence). btsingle.dylib flips one branch so bluetoothd takes its single-instance path.
# It checks the exact bytes first (macOS 26.7.1 25G241 bluetoothd) and logs to /tmp/btsingle.log.
LOG=/Library/NullMoth/bt-syspatch.log
exec > "$LOG" 2>&1
set -x
. "$(dirname "$0")/common.sh" 2>/dev/null || . /Library/NullMoth/common.sh
SRC=${1:-/Library/NullMoth/btmadv/btsingle.dylib}
DY=/System/Library/NullMoth/btsingle.dylib
BK=/Library/NullMoth/sysvol-backup/bt-launchd-$(date +%Y%m%d-%H%M%S)
PB=/usr/libexec/PlistBuddy
[ -f "$SRC" ] || fail "missing $SRC"
sv_mount
P1="$MNT/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
P2="$MNT/System/Library/xpc/launchd.plist"
mkdir -p "$BK" && cp -p "$P1" "$P2" "$BK/" || fail backup
mkdir -p "$MNT/System/Library/NullMoth" && cp "$SRC" "$MNT$DY" || fail "copy dylib"
chown -R root:wheel "$MNT/System/Library/NullMoth"; chmod 755 "$MNT/System/Library/NullMoth" "$MNT$DY"
cmp "$SRC" "$MNT$DY" || fail "verify dylib"
$PB -c "Delete :EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$P1" 2>/dev/null
$PB -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string $DY" "$P1" || fail p1
K=":LaunchDaemons:/System/Library/LaunchDaemons/com.apple.bluetoothd.plist:EnvironmentVariables:DYLD_INSERT_LIBRARIES"
$PB -c "Delete $K" "$P2" 2>/dev/null
$PB -c "Add $K string $DY" "$P2" || fail p2
chown root:wheel "$P1"; chmod 644 "$P1"; chown root:admin "$P2"; chmod 644 "$P2"
plutil -lint "$P1" "$P2" || fail lint
$PB -c "Print :EnvironmentVariables" "$P1"
$PB -c "Print :LaunchDaemons:/System/Library/LaunchDaemons/com.apple.bluetoothd.plist:EnvironmentVariables" "$P2"
sv_bless
echo "backup: $BK"
echo PATCH-OK
echo PATCHDONE
