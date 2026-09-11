import Foundation

public struct FolderSize: Identifiable, Equatable, Sendable {
    public let url: URL
    public let bytes: Int64
    public let isMoved: Bool          // already a symlink managed by us
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var parentName: String { url.deletingLastPathComponent().lastPathComponent }
}

/// Sizes the direct children of the allowlisted roots.
///
/// ponytail: shells out to `du -skx`, one process per root, run concurrently. A treemap or a
/// bundle-id rollup is out of scope -- DaisyDisk already does that better. The only job here
/// is "help me pick a folder". `-x` keeps it on one device so already-moved folders read as
/// freed rather than re-counting the external copy.
public struct Scanner: Sendable {
    private let allowlist: Allowlist
    public init(allowlist: Allowlist = Allowlist()) { self.allowlist = allowlist }

    public func scanAll() async -> [FolderSize] {
        await withTaskGroup(of: [FolderSize].self) { group in
            for root in allowlist.roots {
                group.addTask { Scanner.sizes(under: root) }
            }
            var all: [FolderSize] = []
            for await chunk in group { all += chunk }
            return all.sorted { $0.bytes > $1.bytes }
        }
    }

    static func sizes(under root: URL) -> [FolderSize] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ), !children.isEmpty else { return [] }

        let symlinks = Set(children.filter {
            (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil
        }.map(\.path))

        // Directories only; a loose file in Application Support is not worth relocating.
        let dirs = children.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !dirs.isEmpty else { return [] }

        let output = duKilobytes(paths: dirs.map(\.path))
        return dirs.compactMap { url in
            guard let kb = output[url.path] else { return nil }
            return FolderSize(url: url, bytes: kb * 1024, isMoved: symlinks.contains(url.path))
        }
    }

    private static func duKilobytes(paths: [String]) -> [String: Int64] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/du")
        process.arguments = ["-skx"] + paths
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [String: Int64] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            // "12345\t/path/with possible spaces"
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let kb = Int64(line[line.startIndex..<tab].trimmingCharacters(in: .whitespaces)) ?? 0
            result[String(line[line.index(after: tab)...])] = kb
        }
        return result
    }
}
