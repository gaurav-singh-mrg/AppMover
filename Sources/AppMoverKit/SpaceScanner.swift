import Foundation

public struct FolderSize: Identifiable, Equatable, Sendable {
    public let url: URL
    public let bytes: Int64
    public let category: FolderCategory
    public let isSymlink: Bool        // already redirected, by us or by hand
    public let needsAdmin: Bool       // not owned by the current user; moving needs authorisation

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var parentName: String { url.deletingLastPathComponent().lastPathComponent }

    /// Where the data actually lives right now: the external target once moved, otherwise
    /// the folder itself. Reported even when the drive is absent, so the user can still see
    /// where their data went.
    public var currentLocation: URL {
        guard isSymlink,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return url }
        return URL(filePath: target)
    }

    /// True when the data is somewhere other than where the app looks for it.
    public var isRelocated: Bool { currentLocation.path != url.path }

    /// Where this lands on the destination drive: <folder>/<category>/<name>.
    public func destinationSubpath(root: String) -> String {
        "\(root)/\(category.destinationFolder)/\(name)"
    }
}

/// Sizes the direct children of the active category roots.
///
/// ponytail: shells out to `du -skx`, one process per root, run concurrently. A treemap is
/// out of scope -- DaisyDisk does that better. `-x` keeps it on one device so already-moved
/// folders read as freed rather than re-counting the external copy.
public struct SpaceScanner: Sendable {
    private let categories: [FolderCategory]
    private let home: URL

    public init(categories: [FolderCategory] = FolderCategory.dataCategories,
                home: URL = URL(filePath: NSHomeDirectory())) {
        self.categories = categories
        self.home = home
    }

    public init(settings: Settings, home: URL = URL(filePath: NSHomeDirectory())) {
        self.init(categories: settings.activeCategories, home: home)
    }

    public func scanAll() async -> [FolderSize] {
        let home = home
        return await withTaskGroup(of: [FolderSize].self) { group in
            for category in categories {
                group.addTask { SpaceScanner.sizes(in: category, home: home) }
            }
            var all: [FolderSize] = []
            for await chunk in group { all += chunk }
            return all.sorted { $0.bytes > $1.bytes }
        }
    }

    static func sizes(in category: FolderCategory, home: URL) -> [FolderSize] {
        let fm = FileManager.default
        let root = category.sourceRoot(home: home)
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ), !children.isEmpty else { return [] }

        let symlinks = Set(children.filter {
            (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil
        }.map(\.path))

        let entries = children.filter { url in
            // Application bundles are directories too, so this keeps both.
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !entries.isEmpty else { return [] }

        let sizes = duKilobytes(paths: entries.map(\.path))
        let me = getuid()
        return entries.compactMap { url in
            guard let kb = sizes[url.path] else { return nil }
            var info = stat()
            let owned = lstat(url.path, &info) == 0 && info.st_uid == me
            return FolderSize(url: url, bytes: kb * 1024, category: category,
                              isSymlink: symlinks.contains(url.path), needsAdmin: !owned)
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
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let kb = Int64(line[line.startIndex..<tab].trimmingCharacters(in: .whitespaces)) ?? 0
            result[String(line[line.index(after: tab)...])] = kb
        }
        return result
    }
}
