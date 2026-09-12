import Foundation

/// One relocated folder.
public struct MoveRecord: Codable, Equatable, Sendable, Identifiable {
    public let source: String        // absolute path on the internal disk
    public let volumeUUID: String    // stable id of the external volume
    public let relativePath: String  // path within that volume
    public let movedAt: Date
    public let sizeBytes: Int64

    public var id: String { source }
    public var sourceURL: URL { URL(filePath: source) }
    public var displayName: String { sourceURL.lastPathComponent }

    /// Where the data lives right now, or nil when the volume is not mounted.
    public func currentTarget() -> URL? {
        Volume.find(uuid: volumeUUID)?.mountPoint.appending(path: relativePath)
    }
}

public enum LinkHealth: Equatable, Sendable {
    case healthy            // symlink resolves to the expected directory
    case volumeMissing      // drive not connected; symlink dangles (apps fail loudly, safely)
    case brokenLink         // something replaced the symlink
    case orphaned           // data on the volume, but no symlink pointing at it
}

/// The record of what has been moved. Immutable: every change returns a new value.
///
/// Lives on the *internal* disk on purpose -- if it lived on the external volume you
/// could not undo anything while that volume was disconnected.
public struct Ledger: Codable, Equatable, Sendable {
    public private(set) var links: [MoveRecord]

    public init(links: [MoveRecord] = []) { self.links = links }

    public func adding(_ record: MoveRecord) -> Ledger {
        Ledger(links: links.filter { $0.source != record.source } + [record])
    }

    public func removing(source: String) -> Ledger {
        Ledger(links: links.filter { $0.source != source })
    }

    public func record(for source: URL) -> MoveRecord? {
        links.first { $0.source == source.path }
    }

    // MARK: - Storage

    static func directory(library: URL) -> URL {
        library.appending(path: "Application Support/AppMover")
    }

    public static var fileURL: URL {
        directory(library: URL(filePath: NSHomeDirectory()).appending(path: "Library"))
            .appending(path: "links.json")
    }

    public static func load(from url: URL = fileURL) -> Ledger {
        guard let data = try? Data(contentsOf: url) else { return Ledger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Ledger.self, from: data)) ?? Ledger()
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Health

    public func health(of record: MoveRecord) -> LinkHealth { Ledger.health(of: record) }

    /// Health is a property of the record and the filesystem, not of the ledger. Static so
    /// the engine can re-check it at the moment it acts, rather than trusting a value the UI
    /// computed when the window opened.
    public static func health(of record: MoveRecord) -> LinkHealth {
        let fm = FileManager.default
        guard let target = record.currentTarget() else { return .volumeMissing }
        let source = record.sourceURL
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: source.path) else {
            return fm.fileExists(atPath: target.path) ? .orphaned : .brokenLink
        }
        var isDir: ObjCBool = false
        let resolves = fm.fileExists(atPath: dest, isDirectory: &isDir) && isDir.boolValue
        return resolves ? .healthy : .brokenLink
    }
}
