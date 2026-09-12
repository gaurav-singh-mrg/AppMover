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
    var strandedBackups: [URL] = []

    private var folders: [FolderSize] = []

    /// What the list actually shows: searched, then sorted.
    var arrangedGroups: [AppGroup] {
        GroupList.arrange(groups, sort: settings.sortOrder, search: searchText)
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

    var movableGroups: [AppGroup] { groups.filter { !$0.movableFolders.isEmpty } }
    var movedGroups: [AppGroup] { groups.filter { $0.isFullyMoved || $0.isPartiallyMoved } }

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
        await measureDestinationIfNeeded()
    }

    /// Benchmarks a drive once and remembers it, rather than on every refresh.
    func measureDestinationIfNeeded() async {
        guard let volume = destination, speeds.speed(forVolume: volume.uuid) == nil else { return }
        guard let speed = try? await Task.detached(priority: .utility, operation: {
            try DriveSpeedTester().measure(volume)
        }).value else { return }
        speeds = speeds.recording(speed, forVolume: volume.uuid)
        try? speeds.save()
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

    /// Moves every not-yet-moved folder in a row, one at a time.
    ///
    /// No group transaction: each folder is recorded as it succeeds, so a row with its
    /// Application Support moved and its Caches not is a legitimate, recoverable state.
    func move(_ group: AppGroup) async {
        guard let volume = destination else {
            errorMessage = "Choose a drive in Settings first."
            return
        }
        let root = settings.destinationFolder
        let allowlist = Allowlist(settings: settings)
        var failures: [String] = []
        // Claimed before the first check, not at the first copy: the checks below await, and
        // until this is set every Move and Undo button in the window is still live.
        busyMessage = "Checking \(group.displayName)…"
        defer { busyMessage = nil }

        for folder in group.movableFolders {
            // An orphan would fail with "destination already exists", which tells the user
            // nothing about the copy still sitting on the drive or how to be rid of it.
            if let record = record(for: folder), health(record) == .orphaned {
                failures.append(
                    "\(folder.category.rawValue): an abandoned copy from an earlier move is "
                    + "still on the drive. Open this row and choose Clean Up first.")
                continue
            }
            // Re-checked per folder, not once for the row: a 40 GB copy takes minutes and
            // the user can launch the app in the middle of it.
            let running = await runningOwners(of: folder, in: group)
            guard running.isEmpty else {
                failures.append(
                    "\(folder.category.rawValue): quit \(running.formatted(.list(type: .and))) first. "
                    + "Moving this folder while it is running would silently discard everything "
                    + "it writes from now until it quits.")
                continue
            }
            busyMessage = "Moving \(group.displayName) — \(folder.category.rawValue)…"
            do {
                let record = try await run {
                    try Engine(allowlist: allowlist).move(
                        source: folder.url, toVolume: volume,
                        subpath: folder.destinationSubpath(root: root))
                }
                ledger = ledger.adding(record)
                try ledger.save()
            } catch {
                failures.append("\(folder.category.rawValue): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        await refresh()
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
        busyMessage = "Removing the abandoned copy of \(record.displayName)…"
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

    func undo(_ record: MoveRecord) async {
        busyMessage = "Restoring \(record.displayName)…"
        defer { busyMessage = nil }
        do {
            try await run { try Engine().undo(record) }
            ledger = ledger.removing(source: record.source)
            try ledger.save()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoAll(_ group: AppGroup) async {
        for folder in group.folders {
            guard let record = record(for: folder) else { continue }
            await undo(record)
        }
    }

    /// Keeps filesystem work off the main actor so the window stays responsive.
    private func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try await work() }.value
    }
}
