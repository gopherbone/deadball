#!/bin/sh
# Build the pdsim host harness and run the checks. Usage: ./run.sh [seasons=10]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SEASONS=${1:-10}
OUT=${PDSIM_OUT:-${TMPDIR:-/tmp}/pdsim_test}
mkdir -p "$OUT"
# the newest CommandLineTools SDK can be too new for this clang's linker (see ../../Makefile)
for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk; do
  [ -d "$sdk" ] && SYSROOT="-isysroot $sdk" && break
done
cc $SYSROOT -std=c99 -O2 -Wall -Wextra -o "$OUT/host" "$HERE/host.c" "$HERE/../pdsim_core.c" -lm
[ -f "$OUT/w/world-$((SEASONS-1)).txt" ] || node "$HERE/dump_world.ts" "$SEASONS" calib "$OUT/w"
"$OUT/host" det "$OUT/w"
"$OUT/host" calib "$OUT/w" "$SEASONS"
"$OUT/host" perf "$OUT/w" 2000
"$OUT/host" fuzz "$OUT/w" 1
"$OUT/host" bots "$OUT/w" 1
"$OUT/host" tactics "$OUT/w"
