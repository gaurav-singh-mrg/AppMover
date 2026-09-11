import Foundation

public struct AppIdentity: Equatable, Sendable {
    public let key: String          // folders sharing a key appear in one row
    public let displayName: String
    public let appURL: URL?         // the .app bundle, when it could be found

    public init(key: String, displayName: String, appURL: URL? = nil) {
        self.key = key
        self.displayName = displayName
        self.appURL = appURL
    }
}

/// Maps a folder to the app it belongs to. The default keys on folder name; the app target
/// supplies a resolver that also understands bundle identifiers.
public protocol AppIdentityResolving: Sendable {
    func identity(for folder: FolderSize) -> AppIdentity
}

public struct NameIdentityResolver: AppIdentityResolving {
    public init() {}
    public func identity(for folder: FolderSize) -> AppIdentity {
        AppIdentity(key: folder.name.lowercased(), displayName: folder.name)
    }
}

/// One app and everything of its that lives on disk.
public struct AppGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let appURL: URL?
    public let folders: [FolderSize]

    public var totalBytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }
    public var isFullyMoved: Bool { folders.allSatisfy(\.isSymlink) }
    public var isPartiallyMoved: Bool { folders.contains(where: \.isSymlink) && !isFullyMoved }
    public var movableFolders: [FolderSize] { folders.filter { !$0.isSymlink } }
    public var needsAdmin: Bool { movableFolders.contains(where: \.needsAdmin) }

    /// Categories present, in a stable order, for the row subtitle.
    public var categorySummary: String {
        FolderCategory.allCases
            .filter { category in folders.contains { $0.category == category } }
            .map(\.rawValue)
            .joined(separator: " · ")
    }

    /// Groups folders into one row per app.
    ///
    /// Every folder lands in exactly one group and no folder is dropped: a folder whose app
    /// cannot be identified keys on its own name rather than collapsing into a shared bucket.
    public static func group(
        _ folders: [FolderSize], using resolver: some AppIdentityResolving
    ) -> [AppGroup] {
        var order: [String] = []
        var buckets: [String: (identity: AppIdentity, folders: [FolderSize])] = [:]

        for folder in folders {
            let identity = resolver.identity(for: folder)
            if buckets[identity.key] == nil {
                order.append(identity.key)
                buckets[identity.key] = (identity, [])
            }
            buckets[identity.key]?.folders.append(folder)
            // Prefer an identity that found a real app bundle, for the name and icon.
            if identity.appURL != nil, buckets[identity.key]?.identity.appURL == nil {
                buckets[identity.key]?.identity = identity
            }
        }

        return order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return AppGroup(id: key,
                            displayName: bucket.identity.displayName,
                            appURL: bucket.identity.appURL,
                            folders: bucket.folders.sorted { $0.bytes > $1.bytes })
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }
}
