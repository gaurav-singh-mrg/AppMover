import Foundation

/// The kinds of folder AppMover knows how to relocate.
///
/// A fixed enum, not a free-form folder picker. Settings toggles which of these are active;
/// settings can never introduce a new root, because a root like `~` would make `~/Library`
/// a direct child and therefore movable.
public enum FolderCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case developer = "Developer"
    case applications = "Applications"

    public var id: String { rawValue }

    /// Folders whose data is moved. Application bundles are opt-in and handled separately.
    public static var dataCategories: [FolderCategory] {
        [.applicationSupport, .caches, .developer]
    }

    public func sourceRoot(home: URL = URL(filePath: NSHomeDirectory())) -> URL {
        switch self {
        case .applications: URL(filePath: "/Applications")
        default: home.appending(path: "Library/\(rawValue)")
        }
    }

    /// Destination folder name. Per-category layout, mirroring ~/Library.
    public var destinationFolder: String { rawValue }

    public var label: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .developer: "Developer data"
        case .applications: "Application bundles"
        }
    }

    public var explanation: String {
        switch self {
        case .applicationSupport: "Saved state, profiles and databases. The usual place to reclaim space."
        case .caches: "Regenerable data. Already excluded from Time Machine, so the safest to move."
        case .developer: "Xcode simulators, archives and device support. Often the largest single win."
        case .applications: "The apps themselves. Disconnecting the drive makes them disappear, not just fail."
        }
    }
}
