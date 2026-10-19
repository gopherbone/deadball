#!/bin/sh
# Screenshot tour: builds the Lua client, runs the Simulator headlessly in fixture mode,
# walks every screen (app/tour.lua) and writes PNGs to docs/screens (or $1).
# Usage: sh playdate/tools/tour.sh [outdir]
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
SDK=${PLAYDATE_SDK_PATH:-$HOME/Developer/PlaydateSDK}
SIM="$SDK/bin/Playdate Simulator.app/Contents/MacOS/Playdate Simulator"
PDX="${PDX:-$HERE/build/deadball-shell.pdx}"
DATA="$SDK/Disk/Data/com.deadball.game"
OUT=${1:-$(cd "$HERE/.." && pwd)/docs/screens}
mkdir -p "$HERE/build" "$DATA" "$OUT"
# build from the staged tree (packed faces/archive/fixtures, see the Makefile)
if [ -z "$NOBUILD" ]; then make -s -C "$HERE" stage-sim && rm -rf "$PDX" && "$SDK/bin/pdc" -k "$HERE/build/stage" "$PDX"; fi
echo "$OUT" > "$DATA/tour.flag"
touch "$DATA/debug.flag"
rm -f "$DATA/tour.done"
[ -f "$DATA/auth.json" ] && cp "$DATA/auth.json" "$DATA/auth.json.bak"
echo '{"fixtures":"dev-token-123"}' > "$DATA/auth.json"
"$SIM" "$PDX" >/dev/null 2>&1 &
PID=$!
i=0
while [ $i -lt 300 ] && [ ! -f "$DATA/tour.done" ]; do sleep 1; i=$((i+1)); done
kill $PID 2>/dev/null || true; sleep 1; kill -9 $PID 2>/dev/null || true
rm -f "$DATA/tour.flag" "$DATA/debug.flag"
[ -f "$DATA/auth.json.bak" ] && mv "$DATA/auth.json.bak" "$DATA/auth.json"
echo "screens in $OUT"
grep -iE "error|tour\] step" "$DATA/debug.log" || true
