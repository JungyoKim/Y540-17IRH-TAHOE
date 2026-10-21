#!/bin/bash
# Y540 eet-guard: Energy Efficient Turbo off (single-thread 3.7 -> about 4.3 GHz) only while the CPU package is cool.
# Reads the package temperature (MSR 0x1B1 readout vs TjMax in 0x1A2) every 2 s through NVAccel's read-only MSR sysctl.
# Boost off (EET back on, 3.7 GHz) at >= HOT C, back on below COOL C. Written for the broken-right-fan period.
# Config: /Library/NullMoth/eet-guard.conf ("HOT=85 COOL=78"). Log: /Library/NullMoth/eet-guard.log
# Undo: sudo launchctl unload -w /Library/LaunchDaemons/com.nullmoth.y540-eetguard.plist (the script sets EET back on when it stops)
HOT=85; COOL=78
[ -f /Library/NullMoth/eet-guard.conf ] && . /Library/NullMoth/eet-guard.conf
LOG=/Library/NullMoth/eet-guard.log
for i in $(seq 1 120); do sysctl -n debug.nvaccel_eet_disable >/dev/null 2>&1 && break; sleep 1; done
rd() { sysctl -w debug.nvaccel_msr_addr=$1 >/dev/null 2>&1; sysctl -n debug.nvaccel_msr 2>/dev/null; }
TJ=$(( ($(rd 418) >> 16) & 255 )); [ "$TJ" -ge 80 ] 2>/dev/null || TJ=100
cleanup() { sysctl -w debug.nvaccel_eet_disable=0 >/dev/null 2>&1; echo "$(date '+%F %T') stop: EET on (3.7 GHz)" >> $LOG; exit 0; }
trap cleanup TERM INT
state=-1; n=0
echo "$(date '+%F %T') start: TjMax $TJ, boost below $COOL C, off at $HOT C" >> $LOG
while :; do
  p=$(( TJ - (($(rd 433) >> 16) & 127) ))
  if [ $state != 1 ] && [ $p -lt $COOL ]; then sysctl -w debug.nvaccel_eet_disable=1 >/dev/null 2>&1; state=1; echo "$(date '+%F %T') $p C: boost ON" >> $LOG
  elif [ $state != 0 ] && [ $p -ge $HOT ]; then sysctl -w debug.nvaccel_eet_disable=0 >/dev/null 2>&1; state=0; echo "$(date '+%F %T') $p C: boost OFF (hot)" >> $LOG; fi
  n=$((n+1)); [ $((n % 300)) = 0 ] && echo "$(date '+%F %T') $p C state $state" >> $LOG
  sleep 2
done
