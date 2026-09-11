import Foundation
import Observation
import AppMoverKit

@MainActor
@Observable
final class AppState {
    var folders: [FolderSize] = []
    var ledger: Ledger = .load()
    var volumes: [Volume] = []
    var destinationUUID: String?
    var isScanning = false
    var busyMessage: String?
    var errorMessage: String?
    var readFailed = false

    private let engine = Engine()
    private let scanner = SpaceScanner()

    var destination: Volume? {
        volumes.first { $0.uuid == destinationUUID }
    }

    /// External, writable volumes that can actually hold relocated data.
    var candidateDestinations: [Volume] {
        volumes.filter { $0.supportsSymlinks && !$0.isReadOnly && $0.mountPoint.path != "/" }
    }

    var movable: [FolderSize] {
        folders.filter { !$0.isSymlink && $0.bytes > 0 }
    }

    /// Symlinks we did not create -- typically ones the user made by hand.
    /// Without this they would vanish: hidden from the list for being links, and absent
    /// from the moved section for having no ledger entry.
    var unmanagedLinks: [FolderSize] {
        let known = Set(ledger.links.map(\.source))
        return folders.filter { $0.isSymlink && !known.contains($0.url.path) }
    }

    var reclaimedBytes: Int64 {
        ledger.links.reduce(0) { $0 + $1.sizeBytes }
    }

    func health(_ record: MoveRecord) -> LinkHealth { ledger.health(of: record) }

    var hasProblem: Bool {
        ledger.links.contains { health($0) != .healthy }
    }

    // MARK: - Actions

    func refresh() async {
        volumes = Volume.mounted()
        if destinationUUID == nil || destination == nil {
            destinationUUID = candidateDestinations.first?.uuid
        }
        ledger = .load()
        isScanning = true
        folders = await scanner.scanAll()
        isScanning = false
        // Application Support is readable by its owner; a total blank means the read was
        // refused, which in practice means Full Disk Access has not been granted.
        readFailed = folders.isEmpty && ledger.links.isEmpty
    }

    func move(_ folder: FolderSize) async {
        guard let volume = destination else {
            errorMessage = "Choose an external drive first."
            return
        }
        let subpath = "AppMover/\(folder.parentName)/\(folder.name)"
        busyMessage = "Moving \(folder.name)…"
        defer { busyMessage = nil }

        do {
            let record = try await run {
                try Engine().move(source: folder.url, toVolume: volume, subpath: subpath)
            }
            ledger = ledger.adding(record)
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

    /// Keeps the filesystem work off the main actor so the window stays responsive.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
