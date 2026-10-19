#!/bin/zsh
# Install and launch a .pdx on a USB-attached Playdate.
# Usage: tools/device.sh [path/to/game.pdx]   (default: playdate/build/deadball.pdx)
set -euo pipefail
setopt NULL_GLOB  # the serial port vanishes while the disk is mounted

PDUTIL="$HOME/Developer/PlaydateSDK/bin/pdutil"
PDX="${1:-playdate/build/deadball.pdx}"
NAME="$(basename "$PDX")"
VOL="/Volumes/PLAYDATE"

port() { local ps=(/dev/cu.usbmodemPD*); print -r -- "${ps[1]:-}"; }

[[ -d "$PDX" ]] || { echo "no such pdx: $PDX" >&2; exit 1; }
P="$(port)"
[[ -n "$P" ]] || { echo "no Playdate found on USB (is it unlocked and plugged in?)" >&2; exit 1; }

echo "mounting data disk via $P"
"$PDUTIL" "$P" datadisk
for i in {1..40}; do [[ -d "$VOL/Games" ]] && break; sleep 0.5; done
[[ -d "$VOL/Games" ]] || { echo "data disk did not mount" >&2; exit 1; }

echo "copying $NAME"
xattr -cr "$PDX" 2>/dev/null || true
rsync -rt --inplace --modify-window=2 --delete --exclude '._*' "$PDX/" "$VOL/Games/$NAME/"
# macOS AppleDouble litter on FAT: only touch our own game (walking all of /Games is slow)
dot_clean -m "$VOL/Games/$NAME" 2>/dev/null || true
rm -f "$VOL/Games/._$NAME"
sync
diskutil eject "$VOL" >/dev/null

echo "waiting for the device to come back"
for i in {1..60}; do P="$(port)"; [[ -n "$P" ]] && break; sleep 0.5; done
[[ -n "$P" ]] || { echo "device did not reconnect" >&2; exit 1; }
sleep 1
"$PDUTIL" "$P" run "/Games/$NAME"
echo "launched /Games/$NAME"
