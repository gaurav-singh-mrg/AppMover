import Foundation

/// A mounted volume, identified by UUID rather than mount path.
///
/// Mount paths are not stable: if anything claims the name first, a drive mounts at
/// "/Volumes/MicroSD 1" and every symlink pointing at "/Volumes/MicroSD" resolves to
/// nothing -- or to someone else's data. Always persist the UUID and re-resolve.
public struct Volume: Equatable, Sendable, Identifiable {
    public let uuid: String
    public let name: String
    public let mountPoint: URL
    public let supportsSymlinks: Bool
    public let isReadOnly: Bool
    public let isCaseSensitive: Bool
    public let availableBytes: Int64

    public var id: String { uuid }

    private static let keys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeSupportsSymbolicLinksKey,
        .volumeIsReadOnlyKey, .volumeSupportsCaseSensitiveNamesKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
    ]

    init?(mountPoint: URL) {
        guard let v = try? mountPoint.resourceValues(forKeys: Volume.keys),
              let uuid = v.volumeUUIDString else { return nil }
        self.uuid = uuid
        self.name = v.volumeName ?? mountPoint.lastPathComponent
        self.mountPoint = mountPoint
        self.supportsSymlinks = v.volumeSupportsSymbolicLinks ?? false
        self.isReadOnly = v.volumeIsReadOnly ?? false
        self.isCaseSensitive = v.volumeSupportsCaseSensitiveNames ?? false
        self.availableBytes = Int64(v.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    public static func mounted() -> [Volume] {
        let keys = Array(keys)
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap(Volume.init(mountPoint:))
    }

    /// Re-resolve a remembered volume to wherever it is mounted *now*.
    public static func find(uuid: String) -> Volume? {
        mounted().first { $0.uuid == uuid }
    }

    public static func containing(_ url: URL) -> Volume? {
        guard let v = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let mount = v.volume else { return nil }
        return Volume(mountPoint: mount)
    }

    /// Rejects destinations that cannot hold relocated app data.
    public func validateAsDestination(source: Volume?, requiredBytes: Int64) throws {
        guard supportsSymlinks else {
            throw EngineError.volumeUnsuitable(
                reason: "\(name) does not support symbolic links. Reformat as APFS.")
        }
        guard !isReadOnly else {
            throw EngineError.volumeUnsuitable(reason: "\(name) is read-only.")
        }
        if let source, source.isCaseSensitive != isCaseSensitive {
            throw EngineError.volumeUnsuitable(
                reason: "\(name) differs from the startup disk in case sensitivity, which breaks apps subtly.")
        }
        // Headroom so a copy cannot fill the destination completely.
        guard availableBytes > requiredBytes + 1_000_000_000 else {
            throw EngineError.volumeUnsuitable(reason: "Not enough free space on \(name).")
        }
    }
}
