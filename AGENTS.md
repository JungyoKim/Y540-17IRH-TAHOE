# Runbook: installing Y540-17IRH-TAHOE on a new Y540

This file is written for an agent (or a careful person) setting up another Lenovo Legion Y540-17IRH. Follow the steps in
order. Every script prints `OK:`/`PASS` on success and `FAIL:` with a reason otherwise; stop at the first `FAIL` and read
[docs/troubleshooting.md](docs/troubleshooting.md).

## Ground rules

- **Hardware:** Legion Y540-17IRH with **i7-9750HF + GeForce GTX 1660 Ti** (no Intel iGPU; the NVIDIA card drives the
  internal panel). Other Y540 variants are untested. Details: [docs/hardware.md](docs/hardware.md).
- **macOS 26.7.1, build 25G241 only.** The driver build, the KDK, the Bluetooth patch and the system-volume patches are
  tied to this build. Check with `sw_vers -buildVersion`.
- **Never install a macOS update.** It replaces the patched system volume (no sound, no Safari GPU, no Wi-Fi/BT patches)
  and the pinned files will not match the new build. Stage 1 turns automatic updates off.
- **Never downgrade or reflash the BIOS** (BHCN45WW is the last one; Y540 downgrades have bricked boards).
- Ask the owner before erasing any disk. The install erases the target SSD.
- The scripts need `sudo`. Run them from a clone of this repository on the Y540.

## 0. What you need

- NVMe SSD for macOS. Tested: WD Black SN750 1 TB. **Samsung PM981/PM981a do not work** with macOS; replace them.
- Wi-Fi/Bluetooth: **Broadcom BCM94352Z (DW1560)** for Wi-Fi, Bluetooth, Handoff presence and AirDrop (tested). The stock
  Intel 9560 works for Wi-Fi with `itlwm` (+ the HeliPort app) but has no AirDrop; see "Intel 9560" below.
- A 32 GB USB stick, a USB keyboard and mouse (the installer and Recovery may need them), and internet during setup
  (wired Ethernet works out of the box).
- Another computer (Windows, macOS or Linux) with Python 3 to prepare the stick.

## 1. BIOS

- Update to the latest BIOS (BHCN45WW) from Lenovo if it is older. Do not go back afterwards.
- Security: **Secure Boot off**. Boot mode UEFI. Leave the rest at the defaults.
- The Y540 BIOS has no Above 4G Decoding / Resizable BAR option. That is expected: the driver waits about 3 seconds at
  boot (`nvrmsettle=3000`) while it moves the screen off the 256 MB BAR.
- F12 at the Lenovo logo opens the boot menu, F2 the setup.

## 2. The installer stick

The stick needs the macOS **26.7.1 (25G241)** installer and this repository's EFI.

**A. With a Mac available (preferred):**

    softwareupdate --list-full-installers            # 26.7.1 25G241 must be listed
    softwareupdate --fetch-full-installer --full-installer-version 26.7.1
    sudo "/Applications/Install macOS Tahoe.app/Contents/Resources/createinstallmedia" --volume /Volumes/<stick>

The stick keeps its GPT EFI partition; mount it with `sudo diskutil mount <stick disk>s1`.

**B. Windows only:** use NullMoth's [1401](https://github.com/nullmoth/1401) to write a macOS recovery stick. Recovery
installs whatever Tahoe build Apple serves; on 2026-10-21 that was 26.7.1 (25G241). Check the build after installing
(step 5). If Apple has moved to a newer build, finish the install, then use path A from that macOS to put 26.7.1 on the SSD.

**Put this repository's EFI on the stick's EFI partition** (replace whatever is there):

1. Copy the `EFI` folder of this repository to the stick's EFI partition.
2. On the stick, replace `EFI/OC/config.plist` with `EFI/OC/config-installer.plist` (rename it to `config.plist`). The
   installer config lets macOS use the firmware's screen (no NVIDIA driver yet), keeps the small GPU BAR and shows the
   boot picker for 10 s.
3. Broadcom card: add the three OCLP Wi-Fi kexts (Apple binaries, not shipped here) to `EFI/OC/Kexts`:
   `powershell -ExecutionPolicy Bypass -File install\efi\fetch-efi-kexts.ps1 -Efi E:\EFI` on Windows, or
   `bash install/efi/fetch-efi-kexts.sh /Volumes/EFI/EFI` on macOS/Linux. With an Intel 9560 skip this and see below.
4. Give the machine a Mac identity (MacBookPro16,1). Get `macserial` from the OpenCorePkg 1.0.9 release (Utilities) or
   use GenSMBIOS, then:

       macserial -m MacBookPro16,1 -n 1          # prints: MacBookPro16,1 | SERIAL | MLB
       python3 install/efi/set-smbios.py E:\EFI\OC --serial SERIAL --mlb MLB

   The serial must not belong to a real Mac (checkcoverage.apple.com should call it invalid). The internal EFI gets the
   same identity in step 5.

## 3. Install macOS

1. Plug in the stick, USB keyboard and mouse. F12 > the USB stick. In the OpenCore picker choose the installer
   (`Install macOS Tahoe`, or the recovery entry for path B).
2. Disk Utility > View > Show All Devices > select the SSD > Erase: name `Macintosh HD`, **APFS**, **GUID Partition Map**.
3. Install macOS on it. The laptop restarts several times; at each picker choose the `macOS Installer` entry until it
   disappears, then the SSD's macOS entry.

## 4. Setup Assistant

Create the user account when asked. Without the NVIDIA driver, Setup Assistant usually **stops at its last page** (the
Express Set Up / "Updating your Mac" step with a spinning wheel). This is expected:

1. Hold the power button to turn the laptop off.
2. Boot the stick again, choose the SSD's **Recovery** entry, open Utilities > Terminal.
3. Run `bash /Volumes/<stick>/Y540-17IRH-TAHOE/install/recovery-setup.sh <user> <password>` (copy the repository onto a
   stick first). It turns SSH on, marks setup as done and creates the admin account if Setup Assistant had not.
4. Restart into macOS and log in. The screen runs on the firmware framebuffer until stage 1, so it is slow; SSH works.

If Setup Assistant turned **FileVault** on, macOS asks for the password before it starts. Turn it off in System Settings
> Privacy & Security > FileVault if the laptop should restart unattended (the stages below restart it several times).

## 5. Check the build and copy the EFI to the SSD

    sw_vers -buildVersion                              # must print 25G241
    xcode-select --install                             # git and python3 (Command Line Tools)
    git clone https://github.com/JungyoKim/Y540-17IRH-TAHOE.git && cd Y540-17IRH-TAHOE

The SSD's EFI partition is empty after a fresh install. Copy the stick's `EFI` folder (installer config, with the
identity from step 2) to it once by hand: `sudo diskutil mount disk0s1`, copy `EFI`, `sudo diskutil unmount disk0s1`.
Boot once from the SSD with the stick out to confirm its OpenCore starts macOS. From then on
`install/efi/install-efi.sh` updates that EFI, keeps the identity and backs up the old folder to /Library/NullMoth.

## 6. Download the payloads

    bash install/fetch.sh            # Intel 9560: bash install/fetch.sh --no-broadcom

About 3.2 GB: NullMoth 1.13.0, two Kernel Debug Kits, PatcherSupportPkg 2.0.2. Every file is checked against a pinned
SHA-256 and unpacked into `payloads/`. It ends with `PAYLOADS-OK`.

## 7. Stage 1: driver

    sudo bash install/y540-install.sh 1
    sudo bash install/efi/install-efi.sh daily      # the SSD's EFI switches to the driver config
    sudo shutdown -r now

If System Settings > Privacy & Security asks about system software from NullMoth, allow it and restart once more. After
this the panel runs at 1920x1080 120 Hz with Metal 3 (`system_profiler SPDisplaysDataType`). The daily config boots
straight into macOS without a picker; hold **Option (Alt)** or tap **Esc** on a USB keyboard during start to get it.

## 8. Stage 2: system volume (sound, GPU for sandboxed apps, video decoder)

    sudo bash install/y540-install.sh 2
    sudo shutdown -r now

## 9. Stage 3: boot daemons

    sudo bash install/y540-install.sh 3            # CPU boost: boost (default), guard or off

`boost` keeps Energy Efficient Turbo off so one thread reaches about 4.3 GHz instead of 3.7 (+19 %); it needs both fans
working (the CPU still throttles itself at 94 °C). `guard` boosts only below 78 °C. `off` is stock.

## 10. Stage 4: Broadcom Wi-Fi, Bluetooth advertising, AirDrop (BCM94352Z only)

    sudo bash install/y540-install.sh 4
    sudo shutdown -r now

After the restart: System Settings > General > AirDrop & Handoff > **AirPlay Receiver off** (recommended: the card has
one Bluetooth advertising set, which btarb shares between macOS's advertising instances; with AirPlay Receiver on it is
untested). Sign in to iCloud with the same Apple ID as the iPhone and keep Bluetooth on. install/verify.sh must show
"btarb: multi-advertising emulation on" and "advertising instances on the air".

## 11. Verify

    sudo bash install/verify.sh

Expected: `0 FAIL`. The reference laptop prints 32 PASS lines and 0 WARN with the Broadcom card.

## Intel 9560 instead of Broadcom

In `EFI/OC/config.plist` and `config-installer.plist` set `Enabled` to true for `itlwm.kext`,
`IntelBluetoothFirmware.kext` and `IntelBTPatcher.kext`, and to false for both `AirportBrcmFixup` entries,
`IOSkywalkFamily`, both `IO80211FamilyLegacy` entries, `AirPortBrcmNIC-Tahoe`, `BrcmFirmwareData` and `BrcmPatchRAM3`;
also disable `com.apple.iokit.IOSkywalkFamily` under Kernel > Block. Skip fetch-efi-kexts and stage 4. Wi-Fi is then
managed with the HeliPort app. This combination ran on the reference laptop before the Broadcom card was fitted
(2026-10-13 to 10-19) but has not been re-tested with the final build.

## After the install

- Keep `payloads/` if you may redo stage 2 or 4; otherwise delete it (fetch.sh can download it again).
- Maintenance scripts live in /Library/NullMoth: `gpu-syspatch.sh` (after changing GPU bundles), `wifi-syspatch.sh`,
  `bt-syspatch.sh`, `sd-syspatch.sh`, each with its log next to it. Each one blesses a new boot snapshot; originals go to
  /Library/NullMoth/sysvol-backup.
- To undo everything: reinstall macOS from Recovery, or bless the last sealed snapshot from Recovery and run NullMoth's
  `uninstall.sh` from payloads/nullmoth/pkgroot.

