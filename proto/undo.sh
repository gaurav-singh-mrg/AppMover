#!/bin/bash
# AppMover undo: copy back from the external volume, replace the symlink with real data.
set -euo pipefail

SRC="${1:?usage: undo.sh <symlinked-path>}"
RESTORE="${SRC}.appmover.restore"

manifest() {
  local root="$1" n bytes
  n=$(find "$root" -print0 | tr -dc '\0' | wc -c | tr -d ' ')
  bytes=$(find "$root" -type f -print0 | xargs -0 stat -f%z 2>/dev/null | awk '{s+=$1} END{printf "%d", s+0}')
  echo "$n $bytes"
}
nuke() { chmod -N -R "$1" 2>/dev/null || true; rm -rf "$1"; }

[ -L "$SRC" ] || { echo "FAIL: not a symlink"; exit 1; }
DST="$(readlink "$SRC")"
[ -d "$DST" ] || { echo "FAIL: target missing ($DST) -- mount the volume first"; exit 1; }
[ -e "$RESTORE" ] && { echo "FAIL: stale restore dir at $RESTORE"; exit 1; }

DST_M=$(manifest "$DST")

if ! ditto "$DST" "$RESTORE"; then
  echo "FAIL: restore copy failed"; nuke "$RESTORE"; exit 1
fi

R_M=$(manifest "$RESTORE")
if [ "$DST_M" != "$R_M" ]; then
  echo "FAIL: verify mismatch -- ext[$DST_M] restored[$R_M]"; nuke "$RESTORE"; exit 1
fi

rm "$SRC"                 # removes the LINK only -- never recursive, never the target
mv "$RESTORE" "$SRC"
nuke "$DST"               # external copy only after the internal one is in place
echo "OK: restored $SRC ($R_M)"
