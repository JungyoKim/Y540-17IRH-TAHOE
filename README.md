# Y540-17IRH-TAHOE

macOS 26.7.1 Tahoe on the **Lenovo Legion Y540-17IRH** (i7-9750HF, GeForce GTX 1660 Ti) with the NVIDIA card fully
accelerated: Metal 3, the internal 120 Hz panel, HDMI, sleep, sound, Wi-Fi, Bluetooth and AirDrop.

The graphics driver is [NullMoth NVIDIA driver 1.13.0](https://github.com/nullmoth/nvidia-macos-driver) with a build made
for this laptop on top of it (sleep and wake, HDMI hot-plug, clamshell mode, scan-out timing, Metal plug-in fixes). The
rest is OpenCore 1.0.9, the usual acidanthera/dortania kexts, OCLP's Broadcom Wi-Fi files, and two small patches that
bring Bluetooth advertising and AirDrop to a BCM94352Z card.

**To install it on a Y540, follow [AGENTS.md](AGENTS.md)** (step by step, written so another agent can do it).
한국어 요약: [README.ko.md](README.ko.md).

## What works

Tested on the reference laptop in October 2026, macOS 26.7.1 (25G241), BCM94352Z card.

| Area | State |
|---|---|
| Graphics | GTX 1660 Ti, Metal 3, WindowServer composites on the GPU. Internal 17.3" 1920x1080 panel fixed at 120 Hz (30 fps video lands on whole frames, as on a 120 Hz MacBook Pro) |
| External display | HDMI with hot-plug, lid-closed (clamshell) use, Apple logo on the external display at boot |
| Video | Hardware H.264/HEVC decoding (NVDEC) for VideoToolbox, QuickTime and Safari; WebGL in Safari; webcam preview |
| Sleep | Sleep and wake from the menu, the lid and idle; the screen is back 2-3 s after wake |
| Sound | Internal speakers and microphone (AppleHDA 600.2 + AppleALC layout 18, Realtek ALC257) |
| CPU | Single-thread boost to about 4.3 GHz (+19 %), optional temperature guard |
| Wi-Fi | BCM94352Z: 5 GHz 802.11ac (867 Mbps link), AWDL |
| Bluetooth | BCM20702 with LE advertising (one slot), devices and AirPods |
| AirDrop | Mac to iPhone and iPhone to Mac (same Apple ID) |
| Input | Synaptics I2C trackpad, PS/2 keyboard, Fn brightness and media keys |
| Other | Ethernet (RTL8111), webcam, battery, USB ports, boot to desktop in about 40 s |

## Limits

- **Pinned to macOS 26.7.1 (25G241).** Do not update macOS; an update removes the system-volume patches.
- The macOS brightness slider does not work. The Fn brightness keys do (the firmware handles them).
- One Bluetooth advertising slot: keep AirPlay Receiver off so AirDrop can advertise. Other Continuity features
  (Universal Clipboard, Sidecar, Apple Watch unlock) are untested.
- While a Bluetooth LE mouse or keyboard is connected, the Mac keeps advertising but as non-connectable (the chip cannot
  do both), so other devices cannot open an LE connection to it during that time. AirDrop works either way.
- iPhone-to-Mac AirDrop needs a fresh iCloud Bluetooth pairing between the two; the first tries after pairing can fail.
- The BIOS has no Resizable BAR, so the driver waits about 3 s at boot while it takes over the screen.
- Samsung PM981 NVMe SSDs do not work with macOS; use another SSD (WD SN750 tested).
- The GPU copy engine is not used (NVK cannot build that queue here); copies run on the graphics queue.

## Layout

| Path | What it is |
|---|---|
| [AGENTS.md](AGENTS.md) | Install runbook |
| `EFI/` | OpenCore 1.0.9 (RELEASE) for this laptop: `config.plist` (daily, after the driver), `config-installer.plist` (installer and first boots). Mac identity left blank |
| `install/` | `fetch.sh` (downloads + SHA-256 checks), `y540-install.sh` (stages 1-4), `verify.sh`, `recovery-setup.sh`, `efi/` (EFI helpers), `syspatch/` (system-volume scripts) |
| `macos/overlay/` | The Y540 driver build, copied over NullMoth 1.13.0: NVRM, NVAccel, NVRMFB, Metal plug-in, Vulkan library, H.264 decoder |
| `macos/video/` | NullMoth NVDEC system video decoder plug-in |
| `macos/nullmoth/` | Boot scripts and LaunchDaemons (scan-out modes, CPU boost) |
| `macos/continuity/` | `btsingle.dylib` (bluetoothd) and `sdhook.dylib` (sharingd) |
| `src/` | Source patches against NullMoth 1.13.0, the NVRM byte patch, the two dylibs' sources |
| `docs/` | [hardware](docs/hardware.md), [what changed and why](docs/what-changed.md), [troubleshooting](docs/troubleshooting.md), driver build history, checksums |

Not included, downloaded at install time with pinned SHA-256: the NullMoth 1.13.0 package, Apple's Kernel Debug Kits
(AppleHDA), OCLP's PatcherSupportPkg and Wi-Fi kexts. See [NOTICE.md](NOTICE.md).

## License

PolyForm Noncommercial 1.0.0 ([LICENSE](LICENSE)), the license of the NullMoth driver this builds on: free to use, change
and share, never for money. Third-party parts keep their own licenses; see [NOTICE.md](NOTICE.md).

