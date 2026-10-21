#!/bin/bash
# build.sh -- rebuild macos/continuity/btsingle.dylib and sdhook.dylib (Xcode command line tools, x86_64, ad hoc signed).
set -e
cd "$(dirname "$0")"
O=../../macos/continuity
clang -arch x86_64 -O2 -dynamiclib -o $O/btsingle.dylib btsingle.c
clang -arch x86_64 -O2 -dynamiclib -framework Foundation -lobjc -o $O/sdhook.dylib sdhook.m
codesign -f -s - $O/btsingle.dylib $O/sdhook.dylib
ls -la $O
