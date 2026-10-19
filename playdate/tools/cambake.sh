#!/bin/sh
# Bakes every park's clear-eye picks for BallCast's fixed cameras (changeover, bunt, Pennant's
# decision angles) into source/ballcast/camcache.lua: the devharness "cambake" mode in one
# Simulator (its own bundle id), killed at the end. Re-run after changing a park or those
# cameras; the devharness camaudit mode reports a stale bake.
# Usage: sh playdate/tools/cambake.sh   (needs a Simulator build of pdex.dylib in source/)
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
SDK=${SDK:-$HOME/Developer/PlaydateSDK}
SIM="$SDK/bin/Playdate Simulator.app/Contents/MacOS/Playdate Simulator"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rsync -a --exclude main.lua "$HERE/source/" "$TMP/src/"
printf 'HARNESS_ONLY = "cambake"\nimport "ballcast/devharness"\n' > "$TMP/src/main.lua"
sed -i '' 's/^bundleID=.*/bundleID=com.deadball.cambake/' "$TMP/src/pdxinfo"
"$SDK/bin/pdc" -k "$TMP/src" "$TMP/bake.pdx" 2>&1 | grep -iv "^$\|warning" | head -10 || true
DATA="$SDK/Disk/Data/com.deadball.cambake"
mkdir -p "$DATA"; rm -f "$DATA/harness.log" "$DATA/camcache.lua"
"$SIM" "$TMP/bake.pdx" -NSAppSleepDisabled YES >/dev/null 2>&1 &
PID=$!
i=0
while [ $i -lt 600 ]; do
  sleep 1; i=$((i + 1))
  grep -q "cambake\] wrote\|ERROR" "$DATA/harness.log" 2>/dev/null && { sleep 1; break; }
  kill -0 $PID 2>/dev/null || break
done
kill -9 $PID 2>/dev/null || true
grep "cambake\]\|ERROR" "$DATA/harness.log" || true
[ -s "$DATA/camcache.lua" ] || { echo "no camcache.lua written" >&2; exit 1; }
cp "$DATA/camcache.lua" "$HERE/source/ballcast/camcache.lua"
echo "wrote source/ballcast/camcache.lua (${i}s)"
