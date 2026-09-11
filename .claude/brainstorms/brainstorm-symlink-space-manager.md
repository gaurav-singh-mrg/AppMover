# Brainstorm: AppMover — reclaim macOS SSD space by relocating folders to external storage

**Date**: 2026-09-11
**Status**: Validated — engine proven end-to-end, awaiting scope decision

## Concept

macOS internal SSD fills up. Some app data (`~/Library/Application Support/<app>`, caches)
can't be relocated through any app-provided setting. AppMover moves a chosen folder to an
external SSD, leaves a symlink behind so the app is none the wiser, and can undo it.
Plus a space view so the user can see what's worth moving.

## The measured problem (this machine, 2026-09-11)

```
/System/Volumes/Data   228Gi total   167Gi used   83% full
~/Library/Caches                     10,117 MB   <-- biggest single win
~/Library/Application Support/Code     3,999 MB
~/Library/Application Support/Google   2,011 MB
~/Library/Application Support/com.apple.wallpaper  911 MB
~/Library/Application Support/Claude     574 MB
~/Library/Application Support/feishin    560 MB
```
169 top-level dirs in Application Support. Caches alone is ~2.5x the largest App Support entry.

## VALIDATED: the engine works

Proven end-to-end, internal -> external APFS, with a synthetic folder containing nested
dirs, spaces in names, xattrs, a 200KB binary, and an internal symlink.

### Move
```bash
ditto "$SRC" "$DST"                       # 1. copy (preserves xattrs/ACLs/resource forks)
# 2. verify: entry count + byte count match, else rm -rf dst and abort
mv "$SRC" "$SRC.appmover.bak"             # 3. rename aside -- NOT delete
ln -s "$DST" "$SRC"                       # 4. link
# 5. verify: readlink resolves, target is a dir; else unlink + restore from .bak
chmod -N -R "$SRC.appmover.bak"; rm -rf "$SRC.appmover.bak"   # 6. only now drop backup
```
The rename-aside in step 3 is the whole safety story: the dangerous window is a rename,
not a delete. If anything after it fails, the original is intact one `mv` away.

### Undo
```bash
DST="$(readlink "$SRC")"                  # refuse if target missing (volume unmounted)
ditto "$DST" "$SRC.restore"
rm "$SRC"                                 # removes the LINK ONLY, never the target
mv "$SRC.restore" "$SRC"
chmod -N -R "$DST"; rm -rf "$DST"
```

### Verified properties
- xattrs survive the cross-volume roundtrip (`com.app.state` intact both ways)
- internal symlinks stay symlinks, not flattened into copies
- write-through works: writing via the link lands on the external volume
- directory reads are fully transparent to the app

## VALIDATED ON REAL DATA: feishin, 559 MB, 4558 entries (2026-09-11)

Run against the real `~/Library/Application Support/feishin`, with a full md5 manifest
(path + type + mode + size + checksum for all 4558 entries) captured before as ground truth.

| Step | Result |
|------|--------|
| Move | 3.4s. `4558 entries / 575,731,329 bytes` matched exactly cross-volume |
| Read through symlink | All 4558 entries + every md5 **identical** to pre-move |
| Internal space freed | `du -shx` -> 0B (559 MB off the internal SSD) |
| Undo | 3.9s. Roundtrip manifest **identical** to original ground truth |
| External cleanup | Target directory removed, no residue |

### BUG FOUND AND FIXED: `du` was the wrong verification metric

The first engine compared `du -sk`. On real data that reports **allocated blocks**, not
logical bytes:
```
du -sk feishin  : 572,588 KB
logical bytes   : 562,237 KB      <- 10 MB / 1.8% drift
```
Block size and APFS compression differ across volumes, so a correct copy would have failed
verification and been rolled back. Now compares entry count + summed logical `stat -f%z`,
which matched byte-exact cross-volume. Entry counting is also NUL-delimited so filenames
containing newlines can't skew it.

### Abort paths, all verified leaving source intact and no residue
dest exists / source already a symlink / source missing / stale backup present /
copy fails mid-flight (read-only destination) -> partial destination removed, source untouched.

### Not verified: app-level behaviour
Feishin does not stay running on this machine **in either state** — same
`codesign_util task_name_for_pid` exit with the data symlinked and with it restored to
internal, and no crash reports. Pre-existing and unrelated to the move, but it means this
run proves *data integrity*, not *app compatibility*. Your manual BlueStacks symlink covers
that half.

## VALIDATED: the dangling-volume failure is SAFE

Simulated an unmounted drive. This was the risk that could have killed the product:

```
ls "$A/"          -> No such file or directory
test -d "$A"      -> NO      (but test -L -> yes, it's a symlink)
mkdir -p "$A/x"   -> FAILS
echo x > "$A/f"   -> FAILS
```
**Nothing materializes on the internal disk.** Apps fail loudly rather than silently
recreating the folder and diverging into two half-states. Data is not lost or split.

Residual risk: an app that defensively `unlink`s a broken symlink and recreates a real
directory would orphan the external copy. Rare, detectable on the next verify pass.

## Scope cuts (what NOT to build)

| Cut | Why |
|-----|-----|
| Treemap / disk visualizer | DaisyDisk & GrandPerspective already do this better. The space view's ONLY job is "help me pick a folder." Ship `du -sxm <root>/*` run in parallel, cached to disk. |
| Per-bundle-ID rollup unioning App Support + Caches + Containers + .app | Speculative. Flat per-folder sizes are enough to choose. |
| Custom filesystem walker | `du` is already there and fast enough across 169 dirs in parallel. |
| Scheduling / automation / profiles | YAGNI. |
| Hardlinks, APFS clones, firmlinks | Clones don't work cross-volume. Symlink is the only mechanism that does the job. |

## Hard constraints

**1. Full Disk Access gates the entire product.**
Cannot be requested programmatically — the user grants it in System Settings, then the app
must relaunch. The grant binds to the *signed bundle identity*, so unsigned/ad-hoc rebuilds
invalidate it on every build. **Set up code signing on day one**, not at ship time.
Proof it matters: `ls ~/Library/Containers/com.apple.Notes/` -> `Operation not permitted`.

**2. Denylist is mandatory** — a free-form picker over `~/Library` is a footgun.

Block outright:
- `~/Library/Containers/*` and `~/Library/Group Containers/*` — TCC denies reads, and even
  with FDA a sandboxed app's profile grants the *literal* container path; sandboxd denies
  the redirect. These will break apps. (2,146 containers + 160 group containers here.)
- `~/Library/Application Support` itself — carries a `group:everyone deny delete` ACL.
- AppMover's own ledger directory.

v1 allowlist: children of `Application Support`, children of `Caches`, `~/Library/Developer`.

**3. Store the volume UUID, never the mount path.**
`/Volumes/MicroSD` is not stable — if anything claims the name first the drive mounts at
`/Volumes/MicroSD 1` and every symlink points at nothing, or at someone else's data.
This machine: `963B80C6-941D-414D-8CCA-C072877FB78F`. Resolve UUID -> current mount point at
link creation and at every verify pass.

**4. Time Machine does not follow symlinks.**
Moving a folder out silently drops it from backups. Per-move warning, not a footnote.
(Note `~/Library/Caches` is already `[Excluded]` from TM — so moving caches costs nothing
backup-wise, which makes it the safest AND largest first target.)

**5. `ditto` can fail on ACL'd sources and leave undeletable turds.**
It writes `.BC.T_*` temp files, applies the source ACL, then renames. A deny-delete ACL
breaks the finalize and the leftover resists `rm -rf`. Observed during testing.
**Every abort path must `chmod -N -R "$DST"` before `rm -rf "$DST"`.**

**6. Both volumes must match on case sensitivity.** Both APFS here. Check before moving;
a case-sensitive external under a case-insensitive internal breaks apps subtly.

**7. External must be APFS or HFS+.** ExFAT/FAT32 have no symlink support and no POSIX
permissions — refuse with a clear message.

## State / ledger

Single JSON file, on the **internal** disk — if it lived on the external you couldn't undo
when the external is missing.

`~/Library/Application Support/AppMover/links.json`
```json
{
  "links": [{
    "source": "/Users/x/Library/Application Support/feishin",
    "volumeUUID": "963B80C6-941D-414D-8CCA-C072877FB78F",
    "relativePath": "AppMover/feishin",
    "movedAt": "2026-09-11T17:28:00Z",
    "sizeBytes": 587202560,
    "excludedFromTimeMachine": false
  }]
}
```
Written immutably: read, build new state, atomic write to temp + rename. Never mutate in place.

## Stack — DECIDED

**Native Swift + SwiftUI.** Tauri was considered and dropped: cross-platform buys ~0 reuse
here (`ditto`, `tmutil`, `diskutil`, TCC and the Library layout are all macOS-only), so the
webview was paying for itself with nothing. Swift also gives the simplest Developer ID
signing path, which matters because FDA binds to the signed bundle identity.

- Non-sandboxed, Developer ID signed. It *cannot* be sandboxed — it needs Full Disk Access.
  No security-scoped bookmarks needed as a result.
- Engine shells out to `ditto` via `Process`. Keep it: `ditto` is the macOS-correct tool for
  resource forks and it is already proven here. Do not reimplement with `FileManager`.
- `MenuBarExtra` for the menu bar item (macOS 13+).
- Tests: Swift Testing (`import Testing`, `@Test`/`#expect`), focused on the abort paths.

## Decisions locked (2026-09-11)

| Question | Decision |
|----------|----------|
| Stack | Native Swift/SwiftUI, not Tauri |
| Folder selection | Allowlist only: children of `Application Support`, `Caches`, `~/Library/Developer`. Containers/Group Containers blocked outright. |
| Drive missing/reconnect | Verify-on-launch + menu bar showing link health. No LaunchAgent daemon in v1. |

## Build order

1. **Manual dry run on one real app.** Quit `feishin` (560MB, non-sandboxed, low stakes),
   run the six steps by hand, launch it, confirm it works, undo, confirm again. ~20 min.
   Everything below is a GUI over what this proves.
2. Rust engine + ledger + denylist, with unit tests for the abort paths.
3. Scanner: parallel `du -sxm`, cached.
4. SwiftUI window: folder list w/ sizes, move button, linked-items list w/ undo,
   dangling-state banner. `MenuBarExtra` showing link health.
5. Developer ID signing + FDA onboarding flow (do this early, not at ship).

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Sandboxed app breaks when container moved | CRITICAL | Denylist Containers / Group Containers |
| Mount path shifts, links point at wrong data | HIGH | Volume UUID resolution, verify pass on launch |
| Backups silently stop covering moved data | HIGH | Per-move TM warning |
| Copy fails midway | HIGH | Rename-aside; original never deleted before verify |
| Abort cleanup itself fails on ACLs | MEDIUM | `chmod -N -R` before every `rm -rf` |
| App unlinks dangling symlink, orphans external copy | MEDIUM | Verify pass on launch flags orphans |
| User moves something with the app running | MEDIUM | Warn to quit target app first; detect via `lsof` |

## Open questions

All three opening questions are resolved above. Remaining, deferrable:

1. Where on the external volume do moved folders land? Proposal: `<volume>/AppMover/<name>`,
   mirroring the source's parent so `Caches/x` and `Application Support/x` don't collide.
2. Should `move` offer to quit the target app first (detect via `lsof`), or just warn?
3. Does the menu bar item need to do anything beyond showing health + opening the window?
