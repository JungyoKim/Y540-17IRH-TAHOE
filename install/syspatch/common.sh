# common.sh -- shared by the system-volume scripts: find the booted system volume, mount it writable, bless a snapshot.
MNT=/System/Volumes/Update/mnt1
fail(){ echo "FAIL: $*"; umount "$MNT" 2>/dev/null; echo PATCHDONE; exit 1; }
sv_mount(){ # sets DEV and NAME, mounts the booted system volume read-write on $MNT
  [ "$(id -u)" = 0 ] || fail "run as root"
  [ "$(sw_vers -buildVersion)" = 25G241 ] || fail "not macOS 26.7.1 (25G241)"
  DEV=$(diskutil info / | awk -F: '/Device Node/{gsub(/ /,"",$2); print $2}' | sed -E 's#/dev/##; s/s1$//')
  NAME=$(diskutil info -plist / | plutil -extract VolumeName raw -o - -)
  [ "$(diskutil info -plist $DEV | plutil -extract VolumeName raw -o - -)" = "$NAME" ] || fail "$DEV is not the booted system volume ($NAME)"
  mount | grep -q " on $MNT " && umount "$MNT"
  mkdir -p "$MNT"
  mount -o nobrowse -t apfs /dev/$DEV "$MNT" || fail "mount $DEV"
  [ "$(plutil -extract ProductBuildVersion raw -o - "$MNT/System/Library/CoreServices/SystemVersion.plist")" = "$(sw_vers -buildVersion)" ] || fail "mounted build differs from the running one (update in progress?)"
}
sv_bless(){ bless --mount "$MNT" --bootefi --create-snapshot || fail bless; umount "$MNT"; diskutil apfs listSnapshots / | head -12; }
