import Foundation

public struct DriveSpeed: Codable, Equatable, Sendable {
    public let megabytesPerSecond: Double
    public let measuredAt: Date

    /// Below this, apps reading from the drive feel noticeably worse than the internal SSD.
    /// Spinning disks, USB 2 enclosures and most SD cards land here.
    public static let slowThreshold: Double = 100

    public var isSlow: Bool { megabytesPerSecond < DriveSpeed.slowThreshold }

    public var summary: String {
        String(format: "%.0f MB/s", megabytesPerSecond)
    }

    public var warning: String {
        "This drive writes at \(summary). Apps reading from here will be slower than "
        + "your internal SSD -- fine for caches and archives, noticeable for active app data."
    }
}

/// Measures sustained write speed of a volume, once, and remembers it per volume UUID.
public struct DriveSpeedTester: Sendable {
    /// Big enough to get past any burst cache, small enough not to annoy.
    static let sampleBytes = 24 * 1024 * 1024

    public init() {}

    public func measure(_ volume: Volume) throws -> DriveSpeed {
        let probe = volume.mountPoint.appending(path: ".appmover-speedtest")
        defer { try? FileManager.default.removeItem(at: probe) }

        // Random bytes, never Data(count:) -- a block of zeros can be compressed or
        // sparse-allocated by APFS, which measures the filesystem rather than the drive.
        // Measured 512 MB/s from a MicroSD that way; it is not a 512 MB/s card.
        var payload = Data(count: DriveSpeedTester.sampleBytes)
        payload.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            arc4random_buf(base, raw.count)
        }
        FileManager.default.createFile(atPath: probe.path, contents: nil)
        let handle = try FileHandle(forWritingTo: probe)
        defer { try? handle.close() }

        let started = Date()
        try handle.write(contentsOf: payload)
        // Without F_FULLFSYNC this times the write cache, not the drive: a MicroSD would
        // measure as fast as RAM. fsync() alone is not enough on macOS.
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) != -1 else {
            throw EngineError.volumeUnsuitable(reason: "Could not measure \(volume.name).")
        }
        let elapsed = Date().timeIntervalSince(started)

        let megabytes = Double(DriveSpeedTester.sampleBytes) / 1_048_576
        return DriveSpeed(megabytesPerSecond: megabytes / max(elapsed, 0.001), measuredAt: Date())
    }
}

/// Remembered measurements, so a drive is benchmarked once rather than on every refresh.
public struct DriveSpeedCache: Codable, Equatable, Sendable {
    private var speeds: [String: DriveSpeed]

    public init(speeds: [String: DriveSpeed] = [:]) { self.speeds = speeds }

    public func speed(forVolume uuid: String) -> DriveSpeed? { speeds[uuid] }

    public func recording(_ speed: DriveSpeed, forVolume uuid: String) -> DriveSpeedCache {
        var copy = speeds
        copy[uuid] = speed
        return DriveSpeedCache(speeds: copy)
    }

    public static var fileURL: URL {
        Ledger.directory(library: URL(filePath: NSHomeDirectory()).appending(path: "Library"))
            .appending(path: "drive-speeds.json")
    }

    public static func load(from url: URL = fileURL) -> DriveSpeedCache {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DriveSpeedCache.self, from: data)
        else { return DriveSpeedCache() }
        return decoded
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
