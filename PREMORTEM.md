# Pre-mortem: AppMover

*It is six months from now. AppMover failed. This is the autopsy.*

Not a code review. Ranked by probability × damage. The engine is genuinely good — these are
the ways a good engine still kills the product.

---

## 1. Silent data loss from moving a running app's folder

**Most likely cause of death. Unrecoverable, and the user won't notice for weeks.**

`Engine.move` never checks whether the owning app is running. The only mitigation is one
sentence inside a confirmation dialog: *"Quit Visual Studio Code first."* Nothing enforces it.

The mechanism, straight off the code path in [Engine.swift:50-93](Sources/AppMoverKit/Engine.swift#L50-L93):

1. `ditto` copies the folder while the app is writing to it — a torn snapshot. A SQLite
   database mid-transaction copies with a WAL that no longer matches its main file.
2. `moveItem(source → backup)` renames the original aside. The running app's open file
   descriptors still point at those inodes and keep working, so nothing looks wrong.
3. `nuke(backup)` unlinks them. The app is now writing into a dead inode. Every write after
   the move is discarded the moment the process exits.

The user quits the app hours later. Their settings, their session, their last N hours of
work are gone, and the new folder on the external drive is the stale mid-copy snapshot.
Verification passed, the ledger says healthy, the symlink resolves. Every safety check the
app has reports success.

`ditto` is the right tool for the wrong question: it guarantees fidelity to what was on disk
at copy time, not consistency with what the app believes is on disk.

**Fix:** `NSWorkspace.shared.runningApplications` → match on bundle id and refuse, don't
warn. `AppIdentityResolver` already builds the bundle-id map, so the data is on hand. Offer
"Quit and move" for apps you can terminate. This is a hard block, not a checkbox.

---

## 2. The structural bet: least-replaceable data → least reliable medium → no backups

**Second most likely. Total loss when it happens.**

Three facts, each documented in the README as accepted cost. Together they are the cause of death:

- **Time Machine does not follow symlinks.** Everything moved silently drops out of backups.
- **The destination is removable media.** In the author's own setup, a MicroSD card — the
  app's own speed test measured it and warns about it.
- **`Application Support` is the headline target** — licenses, profiles, chat history,
  app databases. Not regenerable. Often not synced anywhere.

Month eight, the card fails or is lost. There is no backup, because the app removed the data
from the backup set as a side effect of its core operation. The ledger survives on the
internal disk and tells the user, in precise detail, exactly what they lost and cannot restore.

The confirmation dialog mentions Time Machine in the third sentence of a paragraph the user
is clicking through for the twentieth time. It is a disclosure, not a guardrail.

**Fix:** this needs a product answer, not a code one. Either (a) refuse
`Application Support` on any removable/slow volume and market the app as a cache-and-archive
mover, or (b) require a backup destination for moved data and verify it before the first
move. What can't hold is "warn once per move and let the user decide," because the user has
no way to feel the risk accumulating.

---

## 3. Orphaned state has no repair path, and both buttons are dead ends

**Certain to happen — any Sparkle-based updater triggers it.**

Plenty of macOS apps atomically replace their own support folder: write a new one aside,
`rename()` over the old path. That `rename()` destroys the symlink and leaves a real
directory. So does a reinstall, a Setapp update, or a migration assistant.

The app detects this correctly — `Ledger.health` returns `.orphaned` — and then offers
nothing. Traced through the code:

| Step | Result |
|---|---|
| `SpaceScanner.sizes` sees a real dir | `isSymlink: false` |
| `AppGroup.movableFolders` | non-empty → row shows **Move**, not Undo |
| Move → `Engine.move` | `guard !fm.fileExists(destination)` → **`destinationExists`** |
| Detail-row Undo (record still in ledger) | `guard isSymlink(source)` → **`notASymlink`** |

Both affordances throw. The data is now in two places: a live copy on the internal disk and
an abandoned copy on the external drive that nothing points at and nothing will ever clean
up. Disk usage is *worse* than before the app was installed — which is the one thing it
exists to prevent. Health is only re-evaluated when the window opens, so the user finds out
whenever they next happen to look.

**Fix:** make `.orphaned` a first-class state in the UI with one button — "Remove the
abandoned copy on the drive" (after showing both sizes and dates). Drop the ledger record.
Ten lines and a confirmation.

---

## 4. Undo fails exactly when it's needed

**The recovery story has the same failure mode as the thing it recovers from.**

`Engine.move` calls `volume.validateAsDestination(source:requiredBytes:)` before copying.
`Engine.undo` calls nothing equivalent — [Engine.swift:101-145](Sources/AppMoverKit/Engine.swift#L101-L145)
goes straight from its guards to `ditto`. The asymmetry is the bug.

Undo copies the data *back onto the internal disk*. The user installed this app because that
disk was full. They move 40 GB off, carry on filling the disk, then need to undo — a drive
that's failing, a machine going in for repair. `ditto` runs until the disk is full, fails
partway, and leaves a partial `.appmover.restore` beside the symlink. The next undo attempt
hits `staleBackup` and tells the user to "resolve it manually."

Compounding it: volume identity is a UUID (correct, and the README explains why). But
reformat the drive, restore it from a clone, or have the card's UUID change after a repair,
and every record is permanently `.volumeMissing`. The data is right there on the drive, the
ledger has the relative path, and the app has no "this is the same drive, re-point at it"
affordance. Undo is gone for good.

**Fix:** call `validateAsDestination` in `undo` against the internal volume before copying.
Add a "Relink to a different drive" action that rewrites `volumeUUID` after confirming the
expected relative path exists there.

---

## Second tier — confirmed, cheap to fix

- **No `.appmover.bak` recovery scan at launch.** Lose power between the rename (step 3) and
  the symlink (step 4) and the folder simply isn't there any more. The data is intact one
  `mv` away, but nothing ever looks: `staleBackup` only fires if the user happens to move
  that same folder again. Scan for `*.appmover.bak` and `*.appmover.restore` on launch.
- **Crash after the symlink but before `ledger.save()`** ([AppState.swift:115](Sources/AppMover/AppState.swift#L115)) leaves a
  folder moved with no ledger record. The UI shows "linked by hand" and offers no undo.
  Write a pending-intent record *before* the move; clear it after.
- **`destinationFolder` isn't validated.** `trimmingCharacters(in: " /")` strips spaces and
  slashes but not `..`. Verified: `URL("/Volumes/MicroSD").appending(path: "../Caches/x")`
  standardizes to `/Volumes/Caches/x` — off the chosen volume, onto the boot disk. The free-space
  check then validated the wrong volume, and the abort path's `nuke()` then operates outside
  the chosen volume. Reject any component that is `.` or `..`.
- **Moved folders display as "Zero KB."** `du -skx` does not follow a symlink given as an
  argument — verified: 0 vs 4 KB on an identical tree. Moved rows report 0 bytes and sink to
  the bottom of the size sort. Use the ledger's `sizeBytes` for moved folders.
- **Nothing prevents concurrent moves.** No Move button is disabled while `busyMessage` is
  set. Two moves interleave into overlapping `du` storms and mid-flight `refresh()` calls.
  Engine guards keep it from corrupting data, but the UI state is a mess. One-line fix.
- **The README says 45 tests.** There are 62.

---

## The quiet death: performance advice is inverted

Distinct from the failures above — this one is how the app gets abandoned rather than how it
loses data.

`FolderCategory` calls Caches "the safest to move," which is correct on *safety* —
regenerable, already excluded from Time Machine, zero loss risk. The brainstorm points at it
as the 10 GB headline win. But `DriveSpeed.warning` then tells the user a slow drive is
"fine for caches and archives, noticeable for active app data," and that is backwards.

Caches are the hottest-read data on the machine. Archives are cold. Moving 10 GB of caches to
a 40 MB/s card degrades every app that touches them, all day, on every launch. The user
doesn't lose data, doesn't file a bug, and doesn't connect the slowness to the app — they
just quietly stop using it and undo it if they still can.

**Fix:** invert the copy. Slow drives are fine for *archives and rarely-used app data*, and
actively bad for caches. Rank the recommendation by read frequency, not just size.

---

## What is actually solid

Worth stating so the fixes don't damage it:

- The rename-aside safety model is correct and the ordering is right — copy, verify, rename,
  link, verify the link, *then* drop the original. Every abort path restores.
- Logical bytes instead of `du` for verification. The 1.8% block-size drift is real and would
  have rolled back good copies.
- UUID volume identity, resolved fresh each time.
- Resolving the parent but never the leaf in `Allowlist.check` — subtle and correct.
- The `F_FULLFSYNC` + incompressible-data speed test. Both naive versions were live bugs.
- `nuke()` stripping ACLs first, and `removeIfEmpty` checking emptiness before a recursive
  remove — that second one would otherwise have deleted every sibling on the drive.
- Fallback-per-field settings decoding.
- 62 tests, all passing, including a real-data opt-in roundtrip.

The engine is the part most projects get wrong, and it's the part this one got right. What's
missing is everything around it: the world in which the folder is in use, the drive dies, the
updater fights back, and the disk is full when you need to undo.

---

## If only three things get fixed

1. **Block moves of running apps** (#1) — the only unrecoverable silent-loss path.
2. **Give `.orphaned` a repair button** (#3) — certain to occur, currently a permanent dead end.
3. **Free-space check in `undo`** (#4) — four lines, and it's the difference between a
   recovery story and a recovery story that only works when you don't need it.
