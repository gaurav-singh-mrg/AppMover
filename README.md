# AppMover

Moves folders off a full macOS startup disk onto an external drive, leaving a symlink
behind so apps still find their data. Undo puts everything back.

```
./build-app.sh          # builds AppMover.app
swift test              # 29 tests
```

## Safety model

The original is **renamed aside, never deleted**, until the copy is verified *and* the
symlink resolves:

1. `ditto` to the destination
2. verify entry count + logical bytes
3. rename the original aside
4. create the symlink
5. verify the symlink resolves to a directory
6. only now remove the renamed original

Any failure restores the original and removes the partial copy. Verified on real data
(559 MB / 4558 entries) across three roundtrips: md5-identical every time.

## Things that are load-bearing

- **Verification counts logical bytes, never `du`.** `du` reports allocated blocks, which
  drift ~1.8% across volumes with block size and APFS compression — enough to roll back a
  perfectly good copy.
- **Volumes are identified by UUID, not mount path.** `/Volumes/MicroSD` is not stable; if
  something else claims the name the drive mounts at `/Volumes/MicroSD 1` and every symlink
  points at nothing, or at someone else's data.
- **Sandbox containers are blocked.** TCC denies reads, and even with Full Disk Access a
  sandboxed app's profile grants the *literal* container path, so sandboxd denies the
  redirect. Only children of `Application Support`, `Caches` and `Developer` may move.
- **The ledger lives on the internal disk** (`~/Library/Application Support/AppMover/`), so
  undo still works while the external drive is disconnected.
- **A disconnected drive fails loudly, not silently.** Reads and writes through a dangling
  symlink error out; nothing materialises on the internal disk, so data never diverges.
- **Time Machine does not follow symlinks.** Moved folders drop out of backups. The app
  warns before each move.

## Not built, on purpose

No treemap or disk visualiser — DaisyDisk does that better, and the space list only has to
help you pick a folder. No background agent: link health is checked when the window opens
and from the menu bar.

## Status

Works and is tested. Not yet signed with a Developer ID — the build script signs ad-hoc,
so if Full Disk Access turns out to be needed, the grant must be re-applied after each
rebuild because an ad-hoc signature changes every build.
