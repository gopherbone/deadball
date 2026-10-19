#!/bin/sh
# Counts pdsim's Cortex-M7 instructions per game: builds the engine with the device's compiler
# flags as a bare-metal image and runs it in QEMU's mps2-an500 (a Cortex-M7) with -icount, timing
# with SysTick (calibrated against an exact-length loop). Needs the Arm GNU toolchain + qemu.
#   ./m7.sh <world-0.txt from dump_world.ts> [outdir]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
WORLD=${1:?world-0.txt}
OUT=${2:-${TMPDIR:-/tmp}/pdsim_m7}
mkdir -p "$OUT"
ARM=${ARMBIN:-$(ls -d /Applications/ArmGNUToolchain/*/arm-none-eabi/bin | head -1)}
python3 - "$WORLD" "$OUT/teams.h" <<'PY'
import json, sys
teams = [l[5:] for l in open(sys.argv[1]).read().split('\n') if l.startswith('TEAM ')]
open(sys.argv[2], 'w').write('static const char HOME_JSON[] = %s;\nstatic const char AWAY_JSON[] = %s;\n' % (json.dumps(teams[0]), json.dumps(teams[1])))
PY
"$ARM/arm-none-eabi-gcc" -O2 -mthumb -mcpu=cortex-m7 -mfloat-abi=hard -mfpu=fpv5-sp-d16 -ffunction-sections -fdata-sections \
  -I"$OUT" -T "$HERE/m7.ld" --specs=rdimon.specs -Wl,--gc-sections -Wl,--no-warn-rwx-segments -o "$OUT/m7.elf" "$HERE/m7main.c" "$HERE/../../pdsim_core.c" -lm
: > "$OUT/m7.out"
qemu-system-arm -M mps2-an500 -nographic -semihosting -icount shift=0 -kernel "$OUT/m7.elf" > "$OUT/m7.out" 2>&1 &
PID=$!
for i in $(seq 1 300); do grep -q "parse alone" "$OUT/m7.out" && break; sleep 1; done
kill -9 $PID 2>/dev/null || true
cat "$OUT/m7.out"
