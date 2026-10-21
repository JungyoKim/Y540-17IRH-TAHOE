#!/bin/bash
# verify.sh -- read-only check of an installed Y540 Tahoe system against this repository. Prints PASS/WARN/FAIL lines.
# Run with sudo for the complete set (some checks read root-only state). Exit status = number of FAIL lines.
HERE=$(cd "$(dirname "$0")/.." && pwd); M=$HERE/macos
F=0; W=0
pass(){ echo "PASS  $*"; }
warn(){ echo "WARN  $*"; W=$((W+1)); }
fail(){ echo "FAIL  $*"; F=$((F+1)); }
same(){ cmp -s "$1" "$2"; }

[ "$(sw_vers -buildVersion)" = 25G241 ] && pass "macOS 26.7.1 (25G241)" || fail "macOS build $(sw_vers -buildVersion), expected 25G241"
oc=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null | awk '{print $2}')
[ -n "$oc" ] && pass "OpenCore $oc" || warn "OpenCore version not reported"
csr=$(nvram csr-active-config 2>/dev/null | awk '{print $2}')
[ "$csr" = "C%0a%00%00" ] && pass "csr-active-config 430A0000" || warn "csr-active-config is '$csr' (tested 430A0000)"

echo "--- graphics"
n=$(kmutil showloaded --list-only 2>/dev/null | grep -c com.nullmoth)
[ "$n" = 4 ] && pass "4 NullMoth kexts loaded" || fail "$n NullMoth kexts loaded, expected 4"
for k in NVRM NVAccel NVRMFB; do
  same "$M/overlay/Library/Extensions/$k.kext/Contents/MacOS/$k" /Library/Extensions/$k.kext/Contents/MacOS/$k && pass "$k is the Y540 build" || fail "$k differs from macos/overlay"
done
for f in NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver NVMTLDriver.bundle/Contents/MacOS/libnvdec_h264_t2d.dylib nvmtl/libvulkan_nouveau.dylib nvmtl-allow.txt; do
  same "$M/overlay/Library/GPUBundles/$f" /Library/GPUBundles/$f || { fail "/Library/GPUBundles/$f differs from macos/overlay"; continue; }
  same /Library/GPUBundles/$f /System/Library/Extensions/NullMothGPU/$f && pass "$(basename $f) (also in NullMothGPU)" || warn "$(basename $f) not current in /System/Library/Extensions/NullMothGPU (run gpu-syspatch.sh)"
done
same "$M/video/NullMothNVDEC.bundle/Contents/MacOS/NullMothNVDEC" /System/Library/Video/Plug-Ins/NullMothNVDEC.bundle/Contents/MacOS/NullMothNVDEC && pass "NVDEC video decoder plug-in" || fail "NVDEC plug-in missing or different"
sp=$(system_profiler SPDisplaysDataType 2>/dev/null)
echo "$sp" | grep -q 'GTX 1660 Ti' && pass "GPU: GTX 1660 Ti" || fail "GTX 1660 Ti not listed by system_profiler"
echo "$sp" | grep -q 'Metal Support: Metal' && pass "$(echo "$sp" | grep -m1 'Metal Support' | sed 's/^ *//')" || fail "no Metal support reported"
for s in "debug.nvaccel_iop_dbuf 1" "debug.nvaccel_zflip 1" "debug.nvrmfb_vbl_phase 1" "debug.nvrmfb_vbl_spin_us 100"; do
  set -- $s; v=$(sysctl -n $1 2>/dev/null)
  [ "$v" = "$2" ] && pass "$1 = $v" || warn "$1 = '$v' (expected $2; is com.nullmoth.y540-dbuf loaded?)"
done

echo "--- CPU"
eet=$(sysctl -n debug.nvaccel_eet_disable 2>/dev/null)
if [ -f /Library/LaunchDaemons/com.nullmoth.y540-eet.plist ]; then [ "$eet" = 1 ] && pass "CPU boost on (EET off)" || fail "boost daemon installed but debug.nvaccel_eet_disable = '$eet'"
elif [ -f /Library/LaunchDaemons/com.nullmoth.y540-eetguard.plist ]; then pass "CPU boost guard installed (boost only while cool), now $eet"
else warn "CPU boost off (stock 3.7 GHz single-thread); stage 3 boost|guard turns it on"; fi

echo "--- sound"
kextstat 2>/dev/null | grep -q com.apple.driver.AppleHDA && pass "AppleHDA loaded" || fail "AppleHDA not loaded (stage 2)"
system_profiler SPAudioDataType 2>/dev/null | grep -q 'Internal Speakers' && pass "internal speakers present" || fail "no internal speakers"

echo "--- boot daemons"
for p in com.nullmoth.y540-dbuf; do launchctl print system/$p >/dev/null 2>&1 && pass "$p loaded" || fail "$p not loaded (stage 3)"; done

echo "--- settings"
[ "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null)" = 0 ] && pass "automatic macOS updates off" || warn "automatic macOS updates are on: an update replaces the patched system volume"

if system_profiler SPAirPortDataType 2>/dev/null | grep -qi 'Card Type: Wi-Fi *(0x14E4'; then
  echo "--- Broadcom Wi-Fi / Bluetooth / AirDrop"
  ifconfig awdl0 >/dev/null 2>&1 && pass "awdl0 present" || fail "no awdl0 (wifip2pd enabled? stage 4)"
  same "$M/continuity/btsingle.dylib" /System/Library/NullMoth/btsingle.dylib && pass "btsingle.dylib on the system volume" || fail "btsingle.dylib missing (stage 4)"
  same "$M/continuity/sdhook.dylib" /System/Library/NullMoth/sdhook.dylib && pass "sdhook.dylib on the system volume" || fail "sdhook.dylib missing (stage 4)"
  plutil -p /System/Library/LaunchDaemons/com.apple.bluetoothd.plist 2>/dev/null | grep -q btsingle && pass "bluetoothd starts with btsingle" || fail "bluetoothd plist has no btsingle"
  plutil -p /System/Library/LaunchAgents/com.apple.sharingd.plist 2>/dev/null | grep -q sdhook && pass "sharingd starts with sdhook" || fail "sharingd plist has no sdhook"
  [ "$(defaults read /Library/Preferences/com.apple.bluetooth NCSecondaryAdvInstance 2>/dev/null)" = 0 ] && pass "NCSecondaryAdvInstance = 0" || fail "NCSecondaryAdvInstance not 0"
  tail -1 /tmp/btsingle.log 2>/dev/null | grep -q 'now 0f 1f 00' && pass "btsingle patched the running bluetoothd ($(tail -1 /tmp/btsingle.log | cut -d: -f1))" || fail "btsingle did not patch bluetoothd (see /tmp/btsingle.log)"
  since(){ # process name -> its start time, for a short log window
    local p; p=$(pgrep -x "$1" | head -1); [ -n "$p" ] || return 1
    date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p "$p" | sed 's/^ *//; s/ *$//')" '+%Y-%m-%d %H:%M:%S'
  }
  if [ "$(id -u)" = 0 ]; then
    S=$(since bluetoothd) && log show --start "$S" --end "$(date -j -v+90S -f '%Y-%m-%d %H:%M:%S' "$S" '+%Y-%m-%d %H:%M:%S')" --style compact --predicate 'process == "bluetoothd" AND eventMessage CONTAINS "advertising instances"' 2>/dev/null | grep -q 'supports 1 advertising' && pass "bluetoothd: LE advertising on, 1 instance" || warn "bluetoothd did not log 'supports 1 advertising instances' at its start"
    S=$(since sharingd) && log show --start "$S" --end "$(date -j -v+90S -f '%Y-%m-%d %H:%M:%S' "$S" '+%Y-%m-%d %H:%M:%S')" --style compact --predicate 'process == "sharingd" AND eventMessage CONTAINS "SDHOOK loaded"' 2>/dev/null | grep -q 'method=0x' && pass "sdhook active in sharingd" || warn "sharingd did not log 'SDHOOK loaded' at its start (nobody logged in?)"
  fi
fi
echo "=== $F FAIL, $W WARN"
exit $F
