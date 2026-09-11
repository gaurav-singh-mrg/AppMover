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

    var hasProblem: Bool { ledger.links.contains { health($0) != .healthy } }

    // MARK: - Loading

    func refresh() async {
        volumes = Volume.mounted()
        if destination == nil, let first = candidateDestinations.first {
            settings = settings.with { $0.destinationUUID = first.uuid }
            try? settings.save()
        }
        ledger = .load()
        isScanning = true
        let scanned = await SpaceScanner(settings: settings).scanAll()
        folders = scanned
        let resolver = AppIdentityResolver()
        groups = await Task.detached { AppGroup.group(scanned, using: resolver) }.value
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

        for folder in group.movableFolders {
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
        busyMessage = nil
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        await refresh()
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
