# Reference hardware

Everything in this repository was built and tested on one laptop:

| Part | Detail |
|---|---|
| Model | Lenovo Legion Y540-17IRH, machine type 81Q4 |
| BIOS | BHCN45WW (the last release). Do not downgrade: Y540 BIOS downgrades have left boards without display |
| CPU | Intel Core i7-9750HF (6 cores, no integrated GPU) |
| GPU | NVIDIA GeForce GTX 1660 Ti 6 GB, TU116 (PCI 10de:2191), drives the internal panel and HDMI directly. BAR1 256 MB, no Resizable BAR in the BIOS |
| Panel | 17.3" CMN N173HCE-G33, 1920x1080 144 Hz; used at 120 Hz (the driver offers 120 Hz only, boot-arg `nvpanel144=1` brings 144 back) |
| Memory | 16 GB |
| SSD | WD Black SN750 1 TB (WDS100T3X0C). The factory Samsung PM981 does not work with macOS |
| Wi-Fi / BT | Broadcom BCM94352Z (DW1560): Wi-Fi 14e4:43b1, Bluetooth BCM20702A1 0a5c:6417 on USB port HS14. Factory card was Intel 9560 |
| Audio | Realtek ALC257 (AppleALC layout-id 18) |
| Trackpad | Synaptics, I2C HID 06cb:cd5f (VoodooI2C, `-vi2c-force-polling`) |
| Keyboard | PS/2 (VoodooPS2). The reference unit has a hardware fault on the keyboard's USB/EC path (component L23) that makes the internal keyboard work only on some boots in every OS; that is not a software issue |
| Camera | Chicony UVC 04f2:b6d9 on USB port HS06 |
| Ethernet | Realtek RTL8111 10ec:8168 |
| USB map | HS01-HS04, SS01-SS04, HS06 (camera), HS09, HS14 (Bluetooth) in `USBMap.kext` (with the Tahoe port keys) |
| SMBIOS | MacBookPro16,1 |

## Notes on parts

- **Wi-Fi card:** the BCM94352Z gives Wi-Fi, Bluetooth and AirDrop. Its Bluetooth chip refuses Apple's multi-instance
  advertising, so only one advertising slot exists (enough for AirDrop when AirPlay Receiver is off). A BCM94360NG-class
  card would give all slots, but it was not tested here.
- **Fans:** the CPU boost mode (stage 3 `boost`) needs both fans. With one fan broken, use `guard`.
- **HDMI monitors:** some HDMI 1.4 monitors show "no signal" on one input even at the BIOS stage; try another input.

