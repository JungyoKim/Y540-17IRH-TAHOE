#!/usr/bin/env python3
"""set-smbios.py EFI_OC_DIR --serial SERIAL --mlb MLB [--uuid UUID] [--rom HEX12]

Writes the Mac identity into config.plist and config-installer.plist in EFI_OC_DIR (both, so they stay the same).
Generate SERIAL and MLB for MacBookPro16,1 with OpenCore's macserial or GenSMBIOS, e.g.
    macserial -m MacBookPro16,1 -n 1        ->  "MacBookPro16,1 | <SERIAL> | <MLB>"
Check the serial at https://checkcoverage.apple.com: it should be reported as not valid (never use a real Mac's serial).
UUID defaults to a new random one; ROM defaults to 6 random bytes (the MAC address of en0 also works).
Runs on Windows, macOS and Linux (Python 3, standard library only).
"""
import argparse, os, plistlib, re, secrets, sys, uuid

ap = argparse.ArgumentParser(usage=__doc__)
ap.add_argument("oc_dir")
ap.add_argument("--serial", required=True)
ap.add_argument("--mlb", required=True)
ap.add_argument("--uuid", default=str(uuid.uuid4()).upper())
ap.add_argument("--rom", default=None)
a = ap.parse_args()
if not re.fullmatch(r"[A-Z0-9]{12}", a.serial): sys.exit("serial must be 12 characters A-Z/0-9")
if not re.fullmatch(r"[A-Z0-9]{17}", a.mlb): sys.exit("MLB must be 17 characters A-Z/0-9")
rom = bytes.fromhex(a.rom.replace(":", "")) if a.rom else bytes([0x02]) + secrets.token_bytes(5)
if len(rom) != 6: sys.exit("ROM must be 6 bytes")
for name in ("config.plist", "config-installer.plist"):
    p = os.path.join(a.oc_dir, name)
    if not os.path.exists(p):
        continue
    with open(p, "rb") as f:
        d = plistlib.load(f)
    g = d["PlatformInfo"]["Generic"]
    g.update(SystemSerialNumber=a.serial, MLB=a.mlb, SystemUUID=a.uuid.upper(), ROM=rom)
    with open(p, "wb") as f:
        plistlib.dump(d, f, sort_keys=False)
    print("updated", p, g["SystemProductName"], a.serial, a.uuid.upper(), rom.hex())
