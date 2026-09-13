# AppMover

Moves folders off a full macOS startup disk onto an external drive, leaving a symlink
behind so apps still find their data. Undo puts everything back.

Two tabs: **On This Mac**, everything still on the startup disk, and **Moved**, everything
already on the drive with a button to put it back. One row per app, showing everything of its
that is on disk — Application Support, Caches and Developer data together — expandable to the
individual folders, each showing where its data currently lives with a button to reveal it in
Finder. Settings chooses the drive, the folder on it, and which categories to show. The list
can be searched and sorted by size, name, or location (moved first); the sort persists, the
search does not. A move shows a real progress bar, driven by bytes copied.

## Requirements

- macOS 14 Sonoma or later
- **Xcode** 16 or later, not just the Command Line Tools. `build-app.sh` runs `xcstringstool`,
  which only ships with Xcode. Built and tested with Xcode 26.5 / Swift 6.3.
- `python3`, which the build uses to check translations. Xcode includes it.
- An external drive to move folders onto.

No third-party dependencies, no Xcode project: it is a plain Swift package.

## Setup

```sh
git clone https://github.com/gaurav-singh-mrg/AppMover.git
cd AppMover

# If Xcode lives somewhere unusual, or `xcrun --find xcstringstool` fails:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

./build-app.sh          # release build → ./AppMover.app
open AppMover.app
```

`./build-app.sh debug` builds a debug version instead. Every build replaces `AppMover.app`
from scratch.

### First launch

1. Open **Settings** (the gear in the top bar) and pick the external drive, the folder on it
   (default `AppMover`), and which categories to show.
2. If the window says **Can't read your Library**, click **Open Privacy Settings**, add
   `AppMover.app` under *Full Disk Access*, then quit and reopen the app.
3. The build is signed ad-hoc, so its signature changes on every build. If you granted Full
   Disk Access, remove and re-add the app after each rebuild.

The app keeps its state on the internal disk, in `~/Library/Application Support/AppMover/`:
`settings.json` for preferences and `links.json` for the ledger of moved folders. Keep
`links.json` while anything is moved, because Undo reads it.

## Releasing

```sh
./release.sh 0.2.0
```

Commit first; the script refuses a dirty tree. It tags `v0.2.0`, builds, zips the app and
publishes a GitHub release with `gh`. Each time its window opens, the app asks GitHub for the
latest release and shows a **Download** banner if that release is newer than its own
version. The app never installs anything itself.

- The repository must be public. On a private one GitHub answers 404 and no update is shown.
- The build's version comes from the newest git tag, so tag before building. `release.sh`
  does this for you. If a release fails partway, delete the tag with `git tag -d v0.2.0`
  before running it again.
- Downloads aren't notarized, so macOS blocks the first launch. Open it via **System Settings
  → Privacy & Security → Open Anyway**.

## Development

```sh
swift build                       # compile only
swift test                        # 115 tests, headless, run against temporary folders
swift test --filter EngineTests   # a single suite
```

The UI (`Sources/AppMover`) is a thin SwiftUI layer. Moving, verifying, undoing, scanning and
the ledger live in `AppMoverKit`, which is what the tests cover. You can open `Package.swift` in
Xcode to edit and test, but run the app from the bundle `build-app.sh` makes, because that is
where the icon, `Info.plist` and translations are added.

**Real-drive test.** One suite moves a real folder to a real volume and back, then checks it
byte for byte. It is skipped unless you enable it:

```sh
APPMOVER_REAL_FOLDER="$HOME/Library/Application Support/<some folder>" \
APPMOVER_REAL_VOLUME=/Volumes/<your drive> swift test --filter RealData
```

**App icon.** `Resources/AppIcon.icns` is committed. Run `Resources/make-icon.sh` only after
changing the artwork.

**Translations.** See [Languages](#languages). The build fails if a translation's
placeholders don't match the English string.

### Layout

```
Sources/AppMoverKit/   engine, ledger, scanner, settings: all the logic
Sources/AppMover/      SwiftUI app and menu bar item
Tests/AppMoverKitTests/
Resources/             string catalog, icon, icon generator
build-app.sh           builds, localizes, bundles and signs AppMover.app
proto/                 the original shell prototypes of move and undo
PREMORTEM.md           failure modes considered before building
```

## Languages

English, German, Spanish, French, Japanese and Simplified Chinese, from
`Resources/Localizable.xcstrings`. `build-app.sh` syncs new strings from the code into the
catalog (untranslated) and compiles it into the app. Translate or add a language by opening
the catalog in Xcode. To try one without changing the system language:
`AppMover.app/Contents/MacOS/AppMover -AppleLanguages '(ja)'`.

Folder category names on disk (`Application Support`, `Caches`, …) stay English everywhere:
they are real paths and the keys settings are saved under. The UI shows `FolderCategory.label`.

## Destination layout

Per category, mirroring `~/Library`:

```
<drive>/AppMover/Application Support/<name>
<drive>/AppMover/Caches/<name>
<drive>/AppMover/Developer/<name>
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
  warns before each move, naming the folders it is about to move.
- **Settings can narrow what is movable, never widen it.** Categories are a fixed enum, not a
  folder picker; the blocklist and the direct-child-only rule sit outside anything settings
  can reach. A free-form picker would let `~` make `~/Library` a direct child.
- **Drive speed is measured with `F_FULLFSYNC` and incompressible data.** Without the fsync
  you time the write cache; with a block of zeros APFS compresses it away. Both bugs were
  live here — zeros reported a USB SSD at 512 MB/s in 0.06s.
- **Moving a row is per-folder, not a transaction.** Each folder is recorded as it succeeds,
  so "Application Support moved, Caches not" is a legitimate, recoverable state.
- **Search matches inside a row, not just its title.** Typing "microsoft" finds the row
  named "Visual Studio Code" through its `com.microsoft.VSCode.ShipIt` folder.
- **Folders that could never be moved are not listed at all.** Offering a Move button that
  always fails is worse than omitting the folder.
- **macOS's own folders are hidden, unless an installed app claims them.** Two thirds of
  `~/Library/Caches` is `com.apple.*` — TCC, controlcenter, akd — and none of it belongs to
  an app the user would recognise. The escape hatch is the claim: `com.apple.dt.Xcode`
  resolves to an installed Xcode.app and stays, because it is Xcode's data and the largest
  single win on a developer's disk. A row with anything already moved is never hidden — that
  would hide its Undo, and with it the only route back.
- **The progress bar counts bytes, not steps.** `ditto -V` narrates every file to stderr and
  its byte counts sum to exactly the logical byte count `Manifest` measures, so the bar is
  measured against the same number verification later compares. The narration is drained as
  it arrives: buffered until exit, a large tree overruns the 64K pipe and ditto blocks
  forever writing into a pipe nobody reads.
- **A partly-moved app appears in both tabs.** It has folders left to move and folders
  available to undo, and either one is what the user came for.
- **Settings decode field by field with fallbacks.** Synthesised `Codable` throws on a
  missing key, so adding a preference would make an older settings file fail to load and
  silently reset every other preference, including the chosen drive.
- **Application bundles are opt-in.** Disconnecting the drive makes an app *vanish* rather
  than fail on data access. Apps needing an administrator are flagged, never silently
  escalated; SIP-protected Apple apps are refused.

## Not built, on purpose

No treemap or disk visualiser — DaisyDisk does that better, and the space list only has to
help you pick a folder. No background agent: link health is checked when the window opens
and from the menu bar.

## Status

Works and is tested. Not yet signed with a Developer ID — the build script signs ad-hoc,
so if Full Disk Access turns out to be needed, the grant must be re-applied after each
rebuild because an ad-hoc signature changes every build.
