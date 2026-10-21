# Troubleshooting

## Install

- **Setup Assistant spins forever on its last page.** Expected without the driver. Power off, boot Recovery, run
  `install/recovery-setup.sh` (AGENTS.md step 4).
- **USB keyboard does nothing in the installer.** The USB map must have the Tahoe keys (`usb-port-number`,
  `usb-port-type`); the `USBMap.kext` here has them. Check that the stick boots this repository's EFI.
- **Black screen while installing.** The stick must use `config-installer.plist` (renamed to config.plist): it lets macOS
  use the firmware framebuffer. The daily config blocks IONDRVSupport, which only works once the NVIDIA driver is in.
- **Asked for a password before macOS starts.** FileVault was turned on by Setup Assistant. Turn it off in System
  Settings > Privacy & Security, or type the password at every start.

## Driver

- **First start after stage 1 pauses at "PCI configuration end" or shows a frozen screen for a few seconds.** The driver
  waits about 3 s (no Resizable BAR) and, on the very first start, longer while it sets the GPU up. Wait a minute.
- **macOS does not reach the desktop after stage 1.** Boot the stick (installer config), log in, run
  `sudo bash payloads/nullmoth/pkgroot/uninstall.sh` and restart, then read /Library/NullMoth/y540-install.log.
- **"FAIL: auxiliary collection has N NullMoth kexts".** Allow the extensions in Privacy & Security, restart, run the
  stage again.
- **Stage 2 cannot mount the system volume.** SIP must allow it: `csr-active-config` 430A0000 in the OpenCore config.
- **Panel stays black after wake.** Should not happen with this build. If it does, write 1 to the panel relink sysctl over
  SSH (`sudo sysctl -w debug.nvrmfb_relink=1`), or close and open the lid.
- **HDMI monitor says "no signal".** Try another input on the monitor (some HDMI 1.4 inputs fail even at the BIOS logo),
  then re-seat the cable. Hot-plug is supported.

## Sound, Wi-Fi, Bluetooth

- **No sound after a macOS update.** The update replaced the patched system volume and the build no longer matches the
  KDK. Reinstall macOS 26.7.1 (keep the data volume) and rerun stages 2 and 4.
- **Only some 5 GHz channels.** `brcmfx-country` must be `#a` (DeviceProperties of the Wi-Fi card in config.plist).
- **No AirDrop at all / no Handoff presence.** Run `install/verify.sh`. `/tmp/btsingle.log` must show `now 0f 1f 00`,
  retry101, legacyconn v1/v2, nouhe and `prio: hooked` for the current bluetoothd pid, and /tmp/btarb.log `btarb loaded`;
  `defaults read /Library/Preferences/com.apple.bluetooth NCSecondaryAdvInstance` must print 0; AirPlay Receiver must be
  off.
- **The iPhone does not list the Mac, or lists it and the transfer fails, while a Bluetooth LE mouse or keyboard is
  connected.** Older builds stopped advertising for as long as the Mac held an LE link as master. /tmp/btarb.log must show
  `adv params scannable while master` (or `bd adv params: type 0 -> 2`) after a `le conn complete ... role 0` line; a long
  run of `hold adv enable (initiating 0 masters 1)` means the old build is running. Range is not the limit: the card's
  antennas receive the router like a desktop Intel AX211 (within a few dB), and AWDL peers were found at -56 to -67 dBm
  from another room.
- **Bluetooth drops for a moment when the iPhone rings or Instant Hotspot is used.** That was bluetoothd restarting itself
  after a refused LE connection (fixed by btarb, see what-changed.md). If it happens again, look for "Bluetooth error -
  restarting" in bluetoothd's log and for the arbiter's decisions in /tmp/btarb.log. Turning Wi-Fi off and on can still
  restart the Bluetooth stack once (shared Wi-Fi/Bluetooth chip).
- **Mac can send to the iPhone, but the iPhone does not list the Mac or stays at "Waiting".** Both devices need the same
  Apple ID and a current iCloud Bluetooth pairing. Remove old Bluetooth pairing records of the iPhone on the Mac and of the
  Mac on the iPhone, keep both awake for a few minutes, and try again. To see the Mac's decision, enable rapportd debug
  logging (`sudo log config --subsystem com.apple.rapport --mode level:debug`) and look for "Evaluating target AuthTag"
  and "is a match" in rapportd's log while sending.
- **bluetoothd crashes in a loop.** Do not replace /usr/sbin/bluetoothd itself; the dylib approach leaves it unmodified. To
  remove the patch, restore the plists from /Library/NullMoth/sysvol-backup/bt-launchd-* with a writable system-volume
  mount and bless (see `install/syspatch/common.sh`).

