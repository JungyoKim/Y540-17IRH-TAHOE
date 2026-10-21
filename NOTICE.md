# Notices and credits

This repository is licensed under the PolyForm Noncommercial License 1.0.0 ([LICENSE](LICENSE)), the same license as the
NullMoth driver it modifies. The parts listed below keep their own licenses.

## NullMoth NVIDIA driver (modified here)

The files in `macos/overlay/` and `macos/video/` and the patches in `src/nullmoth/` are changed builds of the NullMoth
NVIDIA Metal driver 1.13.0 by NullMoth Systems, https://github.com/nullmoth/nvidia-macos-driver, licensed PolyForm
Noncommercial 1.0.0 (https://polyformproject.org/licenses/noncommercial/1.0.0). NullMoth's own third-party notice:

- translator: based on metal2vulkan by Anees Iqbal, LGPL-3.0-or-later.
- kexts: built against NVIDIA's open GPU kernel modules (r610), MIT/GPL-2.0.
- NVK: Mesa (MIT); NullMoth's changes ship as patches.
- GSP firmware: NVIDIA's redistributable firmware licence (installed by the NullMoth package, not shipped here).

The NullMoth name and logo belong to NullMoth Systems. This project is not affiliated with NullMoth Systems.

## EFI (OpenCore and kexts, unmodified)

OpenCore 1.0.9 (acidanthera, BSD-3-Clause, dortania build 81ecf1a). Kexts: Lilu, WhateverGreen, AppleALC, VirtualSMC
and its SMC plug-ins, RestrictEvents, NVMeFix, BrightnessKeys, BrcmPatchRAM3/BrcmFirmwareData/BlueToolFixup,
VoodooPS2Controller (acidanthera); CpuTscSync, AirportBrcmFixup (lvs1974); VoodooI2C, VoodooI2CHID (VoodooI2C project,
GPL-2.0); YogaSMC (zhen-zen); itlwm, IntelBluetoothFirmware, IntelBTPatcher (OpenIntelWireless); AMFIPass, USBToolBox
(dhinakg); RealtekRTL8111 (Mieze); XHCI-unsupported (RehabMan). Each project's license applies to its files.

## Not included (downloaded at install time)

These contain Apple software or are large upstream releases. The scripts download them from their public sources and
check pinned SHA-256 values:

- NullMoth 1.13.0 package `nullmoth-nvidia-1.13.0.tar.gz` (GitHub release v1.13.0).
- Kernel Debug Kits 26.7.1 (25G241) and 26.0 (25A5279m) from dortania/KdkSupportPkg (AppleHDA comes from the 26.0 one).
- PatcherSupportPkg 2.0.2 `Universal-Binaries.dmg` (dortania), folder 13.7.2-25 (Wi-Fi frameworks, wifip2pd).
- OCLP 3.0.0-rc.3 Wi-Fi kexts IOSkywalkFamily, IO80211FamilyLegacy, AirPortBrcmNIC-Tahoe (dortania/OpenCore-Legacy-Patcher).

macOS, AppleHDA and the other Apple components remain Apple's software under Apple's license terms.

