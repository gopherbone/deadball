#!/bin/sh
# pdc wrapper used by the Makefile (PDC=...): compiles the staged tree (build/stage, see the
# Makefile's stage targets) wherever the SDK's common.mk passes the raw `Source` dir.
REAL="${REAL_PDC:-$HOME/Developer/PlaydateSDK/bin/pdc}"
STAGE="${STAGE_DIR:-build/stage}"
[ -d "$STAGE" ] || { echo "pdc-staged: no $STAGE (run make stage-sim / stage-device)" >&2; exit 1; }
n=$#
i=0
while [ $i -lt $n ]; do
  a=$1; shift
  case "$a" in Source|source|Source/|source/) a=$STAGE ;; esac
  set -- "$@" "$a"
  i=$((i + 1))
done
exec "$REAL" "$@"
