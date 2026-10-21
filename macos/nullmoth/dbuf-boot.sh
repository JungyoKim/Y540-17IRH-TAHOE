#!/bin/sh
# Y540: turn on NVAccel's double-buffered scan-out (debug.nvaccel_iop_dbuf) once NVAccel has registered its sysctls, then
# lock the VBL tick to the panel's scan-out (debug.nvrmfb_vbl_phase, NVRMFB fbdb3 and later) and wait out its last
# microseconds on the raster (debug.nvrmfb_vbl_spin_us, fbdb3g and later).
# Modes: /Library/NullMoth/dbuf-mode (0 off, 1 two buffers, 2 three buffers), default 1;
#        /Library/NullMoth/vblphase-mode (0 free-running timer, 1 locked to the raster), default 1;
#        /Library/NullMoth/vblspin-us (0 timer only, up to 500), default 100.
#        /Library/NullMoth/zflip-mode (0 copy every frame, 1 scan out of the surface's own VRAM), default 1.
# Undo: remove the LaunchDaemon (or write 0 to the mode files).
V=$(cat /Library/NullMoth/dbuf-mode 2>/dev/null || echo 1)
i=0; ok=0
while [ $i -lt 180 ]; do
  /usr/sbin/sysctl -w debug.nvaccel_iop_dbuf=$V >/dev/null 2>&1 && { echo "$(date) dbuf=$V after $i s"; ok=1; break; }
  sleep 1; i=$((i+1))
done
[ $ok = 1 ] || echo "$(date) dbuf sysctl never appeared"
# Y540 zflip (NVAccel accdb8 and later): frames whose newest pixels are in their IOSurface's VRAM are scanned out directly
# (l10r as X2B10G10R10 with R/B swapped in NVRMFB fbdb3z's CSC). /Library/NullMoth/zflip-mode: 0 copy, 1 direct (default)
ZF=$(cat /Library/NullMoth/zflip-mode 2>/dev/null || echo 1)
[ $ok = 1 ] && /usr/sbin/sysctl -w debug.nvaccel_zflip=$ZF >/dev/null 2>&1 && echo "$(date) zflip=$ZF" || echo "$(date) zflip sysctl not set"
P=$(cat /Library/NullMoth/vblphase-mode 2>/dev/null || echo 1)
SP=$(cat /Library/NullMoth/vblspin-us 2>/dev/null || echo 100)
j=0
while [ $j -lt 60 ]; do
  /usr/sbin/sysctl -w debug.nvrmfb_vbl_phase=$P >/dev/null 2>&1 && {
    /usr/sbin/sysctl -w debug.nvrmfb_vbl_spin_us=$SP >/dev/null 2>&1 && echo "$(date) vbl_phase=$P spin_us=$SP after $j s" || echo "$(date) vbl_phase=$P after $j s (no spin sysctl)"
    exit 0; }
  sleep 1; j=$((j+1))
done
echo "$(date) vbl_phase sysctl never appeared"; exit 1
