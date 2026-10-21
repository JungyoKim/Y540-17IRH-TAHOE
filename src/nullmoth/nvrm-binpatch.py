#!/usr/bin/env python3
"""nvrm-binpatch.py IN OUT -- turn NullMoth 1.13.0's NVRM binary into the Y540 build (hp1).

NVRM is NVIDIA's open kernel module built by NullMoth; the Y540 changes are three small byte patches, checked against the
original bytes before they are written. After patching, re-sign the kext ad hoc:  codesign -f -s - NVRM.kext

  0x8896  autoGo: poll for the published display heads every 200 ms instead of every 1000 ms ...
  0x88a5  ... and up to 100 polls instead of 20 (same 20 s limit). The GPU takes over the boot screen ~0.8 s sooner.
  0x13aaf memory scrub: 'rep stosb' over the byte count becomes 'rep stosq' over pages*512 qwords (8x faster zero-fill;
          makes wake from sleep and big allocations faster).
Input: pkgroot/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM from nullmoth-nvidia-1.13.0.tar.gz.
"""
import hashlib, sys

PATCHES = [
    (0x8896, "e8030000", "c8000000"),
    (0x88a5, "14", "64"),
    (0x13aaf, "4889d7488b8d78fffffff3aa", "525f4c89e148c1e109f348ab"),
]

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = bytearray(open(sys.argv[1], "rb").read())
    for off, old, new in PATCHES:
        o, n = bytes.fromhex(old), bytes.fromhex(new)
        cur = bytes(data[off:off + len(o)])
        if cur == n:
            print("0x%x already patched" % off)
            continue
        if cur != o:
            sys.exit("0x%x: found %s, expected %s -- not the NullMoth 1.13.0 NVRM" % (off, cur.hex(), old))
        data[off:off + len(o)] = n
        print("0x%x patched" % off)
    open(sys.argv[2], "wb").write(data)
    print("sha256", hashlib.sha256(data).hexdigest())

if __name__ == "__main__":
    main()
