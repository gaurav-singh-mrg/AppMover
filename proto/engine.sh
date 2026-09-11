#!/bin/bash
# AppMover engine: move a folder to another volume, leave a symlink behind.
# Safety model: the original is never deleted until the copy is verified AND the
# symlink resolves. The dangerous window is a rename, not a delete.
set -euo pipefail

SRC="${1:?usage: engine.sh <source-dir> <dest-dir>}"
DST="${2:?usage: engine.sh <source-dir> <dest-dir>}"
BAK="${SRC}.appmover.bak"

# ponytail: count entries and sum LOGICAL bytes. Never du -- du reports allocated
# blocks, which legitimately differ across volumes (block size, APFS compression)
# and would abort a good copy. Measured 1.8% drift on a real 559MB folder.
manifest() {
  local root="$1" n bytes
  n=$(find "$root" -print0 | tr -dc '\0' | wc -c | tr -d ' ')   # NUL-safe: newlines in names
  bytes=$(find "$root" -type f -print0 | xargs -0 stat -f%z 2>/dev/null | awk '{s+=$1} END{printf "%d", s+0}')
  echo "$n $bytes"
}

# strip ACLs before rm: ditto reproduces source ACLs onto its .BC.T_* temp files,
# and a deny-delete ACL makes the leftovers resist rm -rf.
nuke() { chmod -N -R "$1" 2>/dev/null || true; rm -rf "$1"; }

[ -d "$SRC" ]  || { echo "FAIL: source is not a directory"; exit 1; }
[ -L "$SRC" ]  && { echo "FAIL: source is already a symlink"; exit 1; }
[ -e "$DST" ]  && { echo "FAIL: destination already exists"; exit 1; }
[ -e "$BAK" ]  && { echo "FAIL: stale backup at $BAK -- resolve manually"; exit 1; }

SRC_M=$(manifest "$SRC")
echo "source: $SRC_M (entries bytes)"

mkdir -p "$(dirname "$DST")"

# 1. copy
if ! ditto "$SRC" "$DST"; then
  echo "FAIL: copy failed, removing partial destination"; nuke "$DST"; exit 1
fi

# 2. verify copy before touching the original
DST_M=$(manifest "$DST")
if [ "$SRC_M" != "$DST_M" ]; then
  echo "FAIL: verify mismatch -- src[$SRC_M] dst[$DST_M]"; nuke "$DST"; exit 1
fi
echo "verified: $DST_M"

# 3. rename aside, NOT delete
mv "$SRC" "$BAK"

# 4. link
if ! ln -s "$DST" "$SRC"; then
  echo "FAIL: could not create symlink, restoring"; mv "$BAK" "$SRC"; nuke "$DST"; exit 1
fi

# 5. verify the link actually resolves to a directory
if [ ! -d "$SRC" ] || [ "$(readlink "$SRC")" != "$DST" ]; then
  echo "FAIL: symlink does not resolve, restoring"
  rm -f "$SRC"; mv "$BAK" "$SRC"; nuke "$DST"; exit 1
fi

# 6. only now is it safe to drop the original
nuke "$BAK"
echo "OK: moved -> $DST"
