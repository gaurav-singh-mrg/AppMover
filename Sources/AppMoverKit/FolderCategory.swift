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

    /// What the UI shows. Never `rawValue`: that is the folder's real name on disk and the key
    /// saved settings are stored under, so it must stay English whatever the language.
    public var label: String {
        switch self {
        case .applicationSupport: String(localized: "Application Support")
        case .caches: String(localized: "Caches")
        case .developer: String(localized: "Developer data")
        case .applications: String(localized: "Application bundles")
        }
    }

    public var explanation: String {
        switch self {
        case .applicationSupport:
            String(localized: "Saved state, profiles and databases. The usual place to reclaim space.")
        case .caches:
            String(localized: """
                Regenerable data, already excluded from Time Machine — the safest to move, but \
                read constantly, so a slow drive will be felt.
                """)
        case .developer:
            String(localized: "Xcode simulators, archives and device support. Often the largest single win.")
        case .applications:
            String(localized: "The apps themselves. Disconnecting the drive makes them disappear, not just fail.")
        }
    }
}
