#!/bin/sh
# Simulator test for pdsim: scratch build with source/pdsim/simtest.lua as main.lua, a spec from
# the calibration league, run headless-ish in the Simulator, wait for it, kill only our PID.
#   ./simtest.sh [outdir]       screenshots + pdsim_simtest.log land in outdir
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PD=$(cd "$HERE/../.." && pwd)
SDK=${SDK:-$HOME/Developer/PlaydateSDK}
OUT=${1:-${TMPDIR:-/tmp}/pdsim_sim}
mkdir -p "$OUT"
(cd "$PD" && make >/dev/null 2>&1) || true          # builds pdex.dylib + build/stage (pdc errors elsewhere don't matter here)
[ -f "$PD/build/stage/pdex.dylib" ] || { echo "no staged pdex.dylib"; exit 1; }
rm -rf "$OUT/src"
rsync -a --exclude '/pennant/' "$PD/build/stage/" "$OUT/src/"
sed -i '' 's/^bundleID=.*/bundleID=com.deadball.pdsimtest/' "$OUT/src/pdxinfo"
printf 'PDSIM_OUT = "%s/"\nimport "pdsim/simtest"\n' "$OUT" > "$OUT/src/main.lua"
T=${PDSIM_HOST_OUT:-${TMPDIR:-/tmp}/pdsim_test}
[ -x "$T/host" ] || "$HERE/run.sh" 1 >/dev/null
"$T/host" dumpspec "$T/w" "$OUT/src/pdsim_demo_spec.json" sim-demo
"$SDK/bin/pdc" -q "$OUT/src" "$OUT/simtest.pdx"
DATA="$SDK/Disk/Data/com.deadball.pdsimtest"
rm -f "$DATA/pdsim_simtest.log"
"$SDK/bin/Playdate Simulator.app/Contents/MacOS/Playdate Simulator" "$OUT/simtest.pdx" >/dev/null 2>&1 &
PID=$!
for i in $(seq 1 240); do grep -q "DONE" "$DATA/pdsim_simtest.log" 2>/dev/null && break; sleep 1; done
sleep 1
kill -9 $PID 2>/dev/null || true
cat "$DATA/pdsim_simtest.log"
