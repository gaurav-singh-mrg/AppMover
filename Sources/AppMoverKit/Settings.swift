import Foundation

/// User preferences, stored next to the ledger on the internal disk.
public struct Settings: Codable, Equatable, Sendable {
    public var enabledCategories: Set<FolderCategory>
    public var destinationUUID: String?
    public var destinationFolder: String
    public var moveApplicationBundles: Bool

    public init(
        enabledCategories: Set<FolderCategory> = Set(FolderCategory.dataCategories),
        destinationUUID: String? = nil,
        destinationFolder: String = "AppMover",
        moveApplicationBundles: Bool = false     // opt-in: a different failure mode from data
    ) {
        self.enabledCategories = enabledCategories
        self.destinationUUID = destinationUUID
        self.destinationFolder = destinationFolder
        self.moveApplicationBundles = moveApplicationBundles
    }

    /// Categories actually scanned: application bundles only when explicitly enabled.
    public var activeCategories: [FolderCategory] {
        FolderCategory.allCases.filter { category in
            guard enabledCategories.contains(category) else { return false }
            return category != .applications || moveApplicationBundles
        }
    }

    public func with(_ change: (inout Settings) -> Void) -> Settings {
        var copy = self
        change(&copy)
        return copy
    }

    // MARK: - Storage

    public static var fileURL: URL {
        Ledger.directory(library: URL(filePath: NSHomeDirectory()).appending(path: "Library"))
            .appending(path: "settings.json")
    }

    public static func load(from url: URL = fileURL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return decoded
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
