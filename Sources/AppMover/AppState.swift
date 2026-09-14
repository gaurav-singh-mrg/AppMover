import AppKit
import Foundation
import Observation
import AppMoverKit

@MainActor
@Observable
final class AppState {
    var settings: Settings = .load()
    var ledger: Ledger = .load()
    var groups: [AppGroup] = []
    var volumes: [Volume] = []
    var speeds: DriveSpeedCache = .load()
    var isScanning = false
    var busyMessage: String?
    var errorMessage: String?
    var readFailed = false
    var searchText = ""
    var moveProgress: MoveProgress?
    var strandedBackups: [URL] = []
    /// The version of a newer GitHub release, if there is one.
    var availableUpdate: String?

    private var folders: [FolderSize] = []

    /// What the list actually shows: system folders dropped, searched, then sorted.
    var arrangedGroups: [AppGroup] {
        GroupList.arrange(groups, sort: settings.sortOrder, search: searchText)
    }

    /// What one tab shows. A partly-moved row appears in both on purpose: it has folders
    /// left to move and folders available to undo, and either is what the user came for.
    func groups(in tab: ListTab) -> [AppGroup] { split(arrangedGroups, tab) }

    /// The same tab ignoring the search box -- the denominator in "3 of 40".
    func total(in tab: ListTab) -> Int { split(GroupList.visible(groups), tab).count }

    private func split(_ groups: [AppGroup], _ tab: ListTab) -> [AppGroup] {
        switch tab {
        case .onThisMac: groups.filter { !$0.movableFolders.isEmpty }
        case .moved: groups.filter { $0.isFullyMoved || $0.isPartiallyMoved }
        }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var destination: Volume? { volumes.first { $0.uuid == settings.destinationUUID } }

    var candidateDestinations: [Volume] {
        volumes.filter { $0.supportsSymlinks && !$0.isReadOnly && $0.mountPoint.path != "/" }
    }

    var destinationSpeed: DriveSpeed? {
        destination.flatMap { speeds.speed(forVolume: $0.uuid) }
    }

    var reclaimedBytes: Int64 { ledger.links.reduce(0) { $0 + $1.sizeBytes } }

    func health(_ record: MoveRecord) -> LinkHealth { ledger.health(of: record) }
    func record(for folder: FolderSize) -> MoveRecord? { ledger.record(for: folder.url) }

    var hasProblem: Bool {
        !strandedBackups.isEmpty || ledger.links.contains { health($0) != .healthy }
    }

    /// Nothing may start while something else is mid-flight: two moves interleave into
    /// overlapping `du` storms and refresh() calls that race each other's results.
    var isBusy: Bool { busyMessage != nil }

    // MARK: - Loading

    func refresh() async {
        volumes = Volume.mounted()
        if destination == nil, let first = candidateDestinations.first {
            settings = settings.with { $0.destinationUUID = first.uuid }
            try? settings.save()
        }
        ledger = .load()
        isScanning = true
        let scanner = SpaceScanner(settings: settings)
        let scanned = await scanner.scanAll()
        strandedBackups = scanner.strandedBackups()
        // `du -skx` does not follow a symlink handed to it as an argument, so every folder
        // we have already moved measures as zero and sinks to the bottom of the size sort.
        // Patch the sizes in before grouping -- AppGroup sorts on them.
        let sized = scanned.map { folder -> FolderSize in
            guard folder.isSymlink, let record = ledger.record(for: folder.url) else { return folder }
            return folder.withBytes(record.sizeBytes)
        }
        folders = sized
        let resolver = AppIdentityResolver()
        groups = await Task.detached { AppGroup.group(sized, using: resolver) }.value
        isScanning = false
        readFailed = folders.isEmpty && ledger.links.isEmpty
        await measureDrivesIfNeeded()
    }

    func checkForUpdate() async {
        // Missing under `swift run`, where there is no bundle and nothing to update.
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String else { return }
        // ponytail: offline or rate-limited counts as "no update" -- an alert on every offline
        // launch would be worse than a missed banner, and the next window open asks again.
        availableUpdate = try? await UpdateCheck.newerVersion(than: current)
    }

    /// Benchmarks each drive once and remembers it, rather than on every refresh. Every
    /// connected drive, not just the default: Move can send an app to any of them, and the
    /// slow-drive warning has to be ready before the user picks one.
    func measureDrivesIfNeeded() async {
        for volume in candidateDestinations where speeds.speed(forVolume: volume.uuid) == nil {
            guard let speed = try? await Task.detached(priority: .utility, operation: {
                try DriveSpeedTester().measure(volume)
            }).value else { continue }
            speeds = speeds.recording(speed, forVolume: volume.uuid)
            try? speeds.save()
        }
    }

    /// Sorting only reorders what is already loaded, so it persists without rescanning.
    func setSort(_ order: GroupSort) {
        settings = settings.with { $0.sortOrder = order }
        try? settings.save()
    }

    func updateSettings(_ change: (inout Settings) -> Void) async {
        settings = settings.with(change)
        try? settings.save()
        await refresh()
    }

    // MARK: - Actions

    /// Moves some of a row's folders -- all of them, or the one the user picked -- one at a time.
    ///
    /// No group transaction: each folder is recorded as it succeeds, so a row with its
    /// Application Support moved and its Caches not is a legitimate, recoverable state.
    ///
    /// Any connected drive, not just the one in Settings: every record carries its own volume
    /// UUID, so undo and health checks already follow each folder to whichever drive it is on.
    func move(_ folders: [FolderSize], of group: AppGroup, to chosen: Volume?) async {
        guard let chosen else {
            errorMessage = String(localized: "Choose a drive in Settings first.")
            return
        }
        // Re-resolved rather than trusted from the last scan: its free space is stale -- and
        // that is exactly why the user picked this drive over another -- and it may have been
        // unplugged since.
        guard let volume = Volume.find(uuid: chosen.uuid) else {
            errorMessage = String(localized: "\(chosen.name) is no longer connected.")
            return
        }
        let root = settings.destinationFolder
        let allowlist = Allowlist(settings: settings)
        var failures: [String] = []
        // Claimed before the first check, not at the first copy: the checks below await, and
        // until this is set every Move and Undo button in the window is still live.
        busyMessage = String(localized: "Checking \(group.displayName)…")
        moveProgress = nil
        // One stream for the row, not one per folder: the bar restarts at each folder
        // because each folder is a separate copy, but the plumbing is set up once.
        let (steps, report) = AsyncStream<MoveProgress>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await step in steps { self?.moveProgress = step }
        }
        defer {
            report.finish()
            watcher.cancel()
            busyMessage = nil
            moveProgress = nil
        }

        for folder in folders {
            // An orphan would fail with "destination already exists", which tells the user
            // nothing about the copy still sitting on the drive or how to be rid of it.
            if let record = record(for: folder), health(record) == .orphaned {
                failures.append(
                    String(localized: """
                        \(folder.category.label): an abandoned copy from an earlier move is \
                        still on the drive. Open this row and choose Clean Up first.
                        """))
                continue
            }
            // Re-checked per folder, not once for the row: a 40 GB copy takes minutes and
            // the user can launch the app in the middle of it.
            let running = await runningOwners(of: folder, in: group)
            guard running.isEmpty else {
                failures.append(
                    String(localized: """
                        \(folder.category.label): quit \(running.formatted(.list(type: .and))) \
                        first. Moving this folder while it is running would silently discard \
                        everything it writes from now until it quits.
                        """))
                continue
            }
            busyMessage = String(localized: "Moving \(group.displayName) — \(folder.category.label)…")
            do {
                let record = try await run {
                    try Engine(allowlist: allowlist).move(
                        source: folder.url, toVolume: volume,
                        subpath: folder.destinationSubpath(root: root),
                        progress: { report.yield($0) })
                }
                ledger = ledger.adding(record)
                try ledger.save()
            } catch {
                failures.append("\(folder.category.label): \(error.localizedDescription)")
            }
        }
        labelDriveFolder(volume.mountPoint.appending(path: root))
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        await refresh()
    }

    /// Gives the folder on the drive AppMover's icon, so it reads as the app's data rather
    /// than a folder to tidy away. The root only: an `Icon\r` inside a category folder would
    /// stop `Engine` removing it once empty.
    ///
    /// Skipped once any custom icon is there -- Finder writes the same `Icon\r` file -- so an
    /// icon the user pasted in through Get Info survives.
    private func labelDriveFolder(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              !fm.fileExists(atPath: url.path + "/Icon\r") else { return }
        // ponytail: result ignored -- a plain folder icon is cosmetic, never worth an alert.
        NSWorkspace.shared.setIcon(NSApp.applicationIconImage, forFile: url.path, options: [])
    }

    /// Apps that would lose data if this folder moved out from under them.
    ///
    /// Two independent signals, because each misses what the other catches. Names resolve an
    /// app that is running but holding nothing open at this instant -- it read its config at
    /// launch and will rewrite it on quit, straight into the unlinked inode. Open files
    /// resolve folders whose names identify nothing: "Application Support/Code" belongs to
    /// Visual Studio Code and says so nowhere.
    private func runningOwners(of folder: FolderSize, in group: AppGroup) async -> [String] {
        // NSWorkspace belongs on the main actor; the name match is a few string compares.
        let running = NSWorkspace.shared.runningApplications.map {
            RunningApp(pid: $0.processIdentifier,
                       bundleID: $0.bundleIdentifier,
                       bundlePath: $0.bundleURL?.path)
        }
        let byName = RunningAppCheck.blockers(
            folderNames: [folder.name], appPath: group.appURL?.path, running: running)

        // lsof is a second or so of subprocess and a megabyte of parsing -- long enough to
        // freeze the window if it ran here.
        let path = folder.url.path
        let holders = (try? await run { OpenFiles.holders(under: [path]) }) ?? []
        // ponytail: intersected with NSRunningApplication, which drops the mdworker and
        // backupd false positives but also drops a non-app holder -- a node server or a
        // Homebrew daemon writing into Application Support passes unblocked. Widen to any
        // holder whose executable lives inside a .app if that shows up in practice.
        let byOpenFile = running.filter { holders.contains($0.pid) }.map(\.displayName)
        return Set(byName + byOpenFile).sorted()
    }

    /// Drops the abandoned external copy left when an updater replaced our symlink.
    func discardOrphan(_ record: MoveRecord) async {
        busyMessage = String(localized: "Removing the abandoned copy of \(record.displayName)…")
        defer { busyMessage = nil }
        do {
            try await run { try Engine().discardOrphan(record) }
            ledger = ledger.removing(source: record.source)
            try ledger.save()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo(_ record: MoveRecord) async { await undo([record]) }

    func undoAll(_ group: AppGroup) async { await undo(group.folders.compactMap(record(for:))) }

    /// Restores folders one at a time, the same shape as `move`: each is dropped from the
    /// ledger as it succeeds, and failures are collected rather than each replacing the last.
    /// A row split across two drives with one of them unplugged would otherwise report only
    /// whichever folder failed last, hiding the rest.
    private func undo(_ records: [MoveRecord]) async {
        var failures: [String] = []
        moveProgress = nil
        let (steps, report) = AsyncStream<MoveProgress>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await step in steps { self?.moveProgress = step }
        }
        defer {
            report.finish()
            watcher.cancel()
            busyMessage = nil
            moveProgress = nil
        }
        for record in records {
            busyMessage = String(localized: "Restoring \(record.displayName)…")
            do {
                try await run { try Engine().undo(record, progress: { report.yield($0) }) }
                ledger = ledger.removing(source: record.source)
                try ledger.save()
            } catch {
                failures.append("\(record.displayName): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        await refresh()
    }

    /// Keeps filesystem work off the main actor so the window stays responsive.
    private func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try await work() }.value
    }
}
