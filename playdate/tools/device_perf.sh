#!/bin/zsh
# Hardware perf run on the USB-attached Playdate (fixture mode, no screenshots).
# Installs the build, runs the tour while streaming the frame-time lines over serial,
# switches the device to data-disk mode the moment the tour finishes (before it can
# auto-lock and drop off USB), then restores the account and relaunches the game.
# Usage: zsh playdate/tools/device_perf.sh [pdx]   (default playdate/build/deadball.pdx)
set -euo pipefail
setopt NULL_GLOB
PDUTIL="$HOME/Developer/PlaydateSDK/bin/pdutil"
PDX="${1:-playdate/build/deadball.pdx}"
HERE="${0:A:h}"
VOL="/Volumes/PLAYDATE"
DATA="$VOL/Data/com.deadball.game"
port() { local ps=(/dev/cu.usbmodemPD*); print -r -- "${ps[1]:-}"; }
wait_port() { local P; for i in {1..120}; do P="$(port)"; [[ -n "$P" ]] && { print -r -- "$P"; return; }; sleep 0.5; done; }
mount_disk() {
  # already mounted, or mounting (serial_run just sent datadisk): give macOS a moment
  for i in {1..30}; do [[ -d "$VOL/Games" ]] && return; [[ -n "$(port)" ]] && break; sleep 0.5; done
  local P="$(wait_port)"
  [[ -n "$P" ]] || { echo "no Playdate on USB (wake it up and keep it unlocked)" >&2; exit 1; }
  "$PDUTIL" "$P" datadisk
  for i in {1..40}; do [[ -d "$VOL/Games" ]] && break; sleep 0.5; done
  [[ -d "$VOL/Games" ]] || { echo "data disk did not mount" >&2; exit 1; }
}
eject_disk() { sync; diskutil eject "$VOL" >/dev/null; }

mount_disk
mkdir -p "$DATA"
[[ -f "$DATA/auth.json" && ! -f "$DATA/auth.json.bak" ]] && cp "$DATA/auth.json" "$DATA/auth.json.bak"
echo '{"fixtures":"dev-token-123"}' > "$DATA/auth.json"
touch "$DATA/debug.flag" "$DATA/perftour.flag"
rm -f "$DATA/debug.log" "$DATA/tour.done"
xattr -cr "$PDX" 2>/dev/null || true
rsync -rt --inplace --modify-window=2 --delete --exclude '._*' "$PDX/" "$VOL/Games/deadball.pdx/"
dot_clean -m "$VOL/Games/deadball.pdx" 2>/dev/null || true; rm -f "$VOL/Games/._deadball.pdx"
eject_disk
P="$(wait_port)"; [[ -n "$P" ]] || { echo "device did not come back after eject" >&2; exit 1; }
sleep 1
echo "running perf tour (about 7 minutes)..."
python3 -I "$HERE/serial_run.py" "$P" /Games/deadball.pdx --until "[tour] done" --timeout ${TIMEOUT:-900} || true
# restore normal play
mount_disk
rm -f "$DATA/debug.flag" "$DATA/perftour.flag"
[[ -f "$DATA/auth.json.bak" ]] && mv "$DATA/auth.json.bak" "$DATA/auth.json"
eject_disk
P="$(wait_port)"; [[ -n "$P" ]] && "$PDUTIL" "$P" run "/Games/deadball.pdx" >/dev/null 2>&1 || true
echo "restored; game relaunched normally"
