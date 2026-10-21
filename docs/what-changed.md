# What was changed and why

A summary of the work behind this repository, grouped by area. The per-build notes are in
[driver-build-history.txt](driver-build-history.txt); the source changes in [../src](../src).

## Graphics driver (NullMoth 1.13.0 + Y540 build)

NullMoth targets macOS 15. This laptop runs Tahoe and drives its internal panel from the NVIDIA card, which brought up
problems the upstream build does not hit. Changes, all in `macos/overlay/`:

- **Tahoe support:** NVAccel built for macOS 26 (forwarders for Tahoe's NVResource paging), 10-bit ARGB2101010 screen
  buffers accepted (Tahoe's WindowServer switches to them; the copy path used to refuse every frame).
- **Scan-out:** double-buffered scan-out, direct scan-out from the surface's own VRAM (zflip), VBL tick locked to the
  panel's raster. Enabled at boot by `com.nullmoth.y540-dbuf` (`/Library/NullMoth/*-mode` files). Removes tearing and
  most dropped frames when dragging windows.
- **Panel:** 120 Hz only by default (30 fps video divides evenly), panel relink, fade on display sleep/wake.
- **Sleep and wake:** GPU suspend/resume, display sleep, lid sleep (backlight nub and Apple sense), WindowServer paging
  state restored after wake, NVRM memory scrub 8x faster, held GPU requests while suspended. Wake to picture in 2-3 s.
- **External display:** HDMI port registered at boot (hot-plug works without a monitor at boot), disconnect debounce,
  re-commit after a quick replug, BAR1 give-back so sleeping with a monitor attached does not run out of window,
  clamshell mode (lid closed with HDMI: the panel goes away and the menu bar moves), external display off with display
  sleep, Apple logo on the external display during boot.
- **NVRM:** heads-published poll 1000 -> 200 ms (the GPU takes over the boot screen sooner), 8x faster zero-fill. Byte
  patches, see `src/nullmoth/nvrm-binpatch.py`.
- **Metal plug-in (NVMTLDriver):** shader translation cache made persistent and stored in the background, translator
  preloaded, bindings trimmed per pipeline, texture usage 0 treated as "all" (fixes Photo Booth/Core Image), drawables
  report isDrawable (fixes upside-down camera preview), function-constant re-translation, large uploads from other
  processes split into 4 MB bands so WindowServer is not starved, video surface import cache 16 -> 48 entries (dual
  display lock screen), many smaller fixes for Dock icons, badges, clock and Settings rendering.
- **Video:** NullMoth NVDEC installed as a system video decoder plug-in, faster H.264 detile, no busy-wait for NVDEC.
- **Sandboxed apps:** a system-volume copy of the GPU bundles (`NullMothGPU`) and a /dev/random fallback where the sandbox
  refuses /dev/null, so Safari's GPU process gets Metal and WebGL.

## Sound

Tahoe removed AppleHDA. Stage 2 merges the 26.7.1 Kernel Debug Kit's extensions and AppleHDA 600.2 from the 26.0 beta KDK
into the system volume, rebuilds the kernel collections and the NullMoth auxiliary collection, and blesses a new snapshot
(the same sequence as SimpleLoader). AppleALC layout 18 drives the ALC257.

## CPU

The EC's Energy Efficient Turbo kept single-thread clocks at 3.7 GHz. Turning EET off (MSR 0x1FC bit 19, through a
read/write sysctl in NVAccel) lets one thread reach about 4.3 GHz: +19 % single-thread, 28 W and 86 °C average under a
single-thread load, and the CPU still throttles itself at 94 °C. `boost` keeps it off, `guard` switches it by temperature.

## Wi-Fi (BCM94352Z)

OCLP 3.0.0's "Modern Wireless" approach without OCLP itself: its three kexts in OpenCore, and its system-volume files
(wifip2pd, IO80211 and WiFiPeerToPeer frameworks from macOS 13.7.2) copied with the same rules. OCLP's app is not used
because it rebuilds the auxiliary kernel collection and clears KextPolicy, which drops the NullMoth kexts.
`brcmfx-country=#a` opens all 2.4 and 5 GHz channels (KR gave only 149-161).

## Bluetooth advertising and AirDrop

- **btsingle.dylib:** Tahoe's bluetoothd always asks for Apple's multi-instance advertising (vendor command 0x148). The
  BCM20702 answers "unknown command" and bluetoothd leaves its whole advertising stack off: no Handoff, AirDrop or Find
  My presence. The dylib flips one branch in LeBroadcaster::stackDidStart so bluetoothd uses the single-instance path,
  after checking the exact bytes. `NCSecondaryAdvInstance = 0` sends AirDrop's advertisement to that one slot.
- **sdhook.dylib:** sharingd never matched the iPhone seen over Bluetooth to its iCloud identity (the controller does not
  resolve its private address), so the iPhone lacked the MyiCloud flag and AirDrop discovery dropped it. The hook sets
  that flag for same-account identities, which is what Sharing.framework does itself inside a virtual machine.
- Both are loaded with DYLD_INSERT_LIBRARIES from launchd's plists on the system volume (stage 4).
- iPhone to Mac also needed a fresh iCloud Bluetooth pairing: an old pairing record from 2022 left the iPhone with a stale
  key for the Mac. Removing the record and restarting audioaccessoryd made the two exchange new keys.

## Boot

OpenCore RELEASE build (no debug text on screen), no picker (`Timeout 0`), boot to desktop in about 40 s, of which the
Lenovo logo is 7 s and the GPU takeover chain about 4.5 s.

