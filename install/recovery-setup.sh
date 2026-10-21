#!/bin/bash
# recovery-setup.sh USER PASSWORD -- finish a fresh install whose Setup Assistant hangs.
# Without the NVIDIA driver, Setup Assistant on this laptop stops at its last step ("Updating your Mac" / the Express
# Set Up page) with the spinner turning. Run this from the macOS Recovery Terminal (or from another macOS on the same
# machine): it creates an admin account if Setup Assistant did not get that far, turns SSH on, and marks setup as done.
# On the next normal boot you get the login window. Recovery has no network installer here; copy this file on a USB stick.
set -u
USR=${1:-}; PW=${2:-}
[ -n "$USR" ] && [ -n "$PW" ] || { echo "usage: bash recovery-setup.sh <short user name> <password>"; exit 1; }
die(){ echo "FAIL: $*"; exit 1; }
D=""
for v in /Volumes/*; do [ -d "$v/private/var/db/dslocal/nodes/Default/users" ] && [ -d "$v/Users" ] && D=$v && break; done
[ -n "$D" ] || die "no data volume with a local directory under /Volumes (mount it: diskutil mount '<name> - Data')"
echo "data volume: $D"
N="$D/private/var/db/dslocal/nodes/Default"
BK="$D/private/var/root/y540-recovery-bak-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
L="$D/private/var/db/com.apple.xpc.launchd/disabled.plist"
mkdir -p "$(dirname "$L")"; [ -f "$L" ] && cp -p "$L" "$BK/"
if [ -x /usr/libexec/PlistBuddy ]; then
  [ -f "$L" ] || /usr/libexec/PlistBuddy -c "Save" "$L" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Delete :com.openssh.sshd" "$L" >/dev/null 2>&1
  /usr/libexec/PlistBuddy -c "Add :com.openssh.sshd bool false" "$L" || die "sshd flag"
else
  [ -f "$L" ] && echo "WARN: no PlistBuddy here; disabled.plist replaced (backup in $BK)"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>com.openssh.sshd</key><false/></dict></plist>' > "$L"
fi
chown 0:0 "$L"; chmod 644 "$L"; echo "SSH on at boot"
EXIST=$(dscl -f "$N" localonly -list /Local/Default/Users UniqueID 2>/dev/null | awk '$2 == 501 {print $1}')
if [ -n "$EXIST" ]; then
  echo "user $EXIST (uid 501) already exists (made by Setup Assistant); log in with that account"
else
  echo "creating admin user $USR (uid 501)"
  dscl -f "$N" localonly -create /Local/Default/Users/$USR || die "dscl create"
  dscl -f "$N" localonly -create /Local/Default/Users/$USR UserShell /bin/zsh
  dscl -f "$N" localonly -create /Local/Default/Users/$USR RealName "$USR"
  dscl -f "$N" localonly -create /Local/Default/Users/$USR UniqueID 501
  dscl -f "$N" localonly -create /Local/Default/Users/$USR PrimaryGroupID 20
  dscl -f "$N" localonly -create /Local/Default/Users/$USR NFSHomeDirectory /Users/$USR
  dscl -f "$N" localonly -passwd /Local/Default/Users/$USR "$PW" || die "dscl passwd"
  dscl -f "$N" localonly -append /Local/Default/Groups/admin GroupMembership $USR
  mkdir -p "$D/Users/$USR"; chown 501:20 "$D/Users/$USR"; chmod 755 "$D/Users/$USR"
fi
touch "$D/private/var/db/.AppleSetupDone"
echo "OK -- restart into macOS (log in as $USR), then: sudo bash install/fetch.sh ... see AGENTS.md step 6"
