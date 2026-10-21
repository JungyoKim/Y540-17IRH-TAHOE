#!/bin/bash
# Y540: turn Energy Efficient Turbo off at boot (MSR 0x1FC bit 19) so single-thread loads reach 4.2-4.4 GHz instead of 3.7.
# Installed but NOT loaded: load it only after the broken right fan is replaced:
#   sudo launchctl load -w /Library/LaunchDaemons/com.nullmoth.y540-eet.plist
# Undo: sudo launchctl unload -w /Library/LaunchDaemons/com.nullmoth.y540-eet.plist; sudo sysctl -w debug.nvaccel_eet_disable=0
for i in $(seq 1 60); do sysctl -n debug.nvaccel_eet_disable >/dev/null 2>&1 && break; sleep 1; done
sysctl -w debug.nvaccel_eet_disable=1 >> /Library/NullMoth/eet-boot.log 2>&1
date >> /Library/NullMoth/eet-boot.log
