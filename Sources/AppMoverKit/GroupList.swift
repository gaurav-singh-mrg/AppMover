import Foundation

public enum GroupSort: String, Codable, CaseIterable, Sendable, Identifiable {
    case size
    case name
    case location

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .size: String(localized: "Size")
        case .name: String(localized: "Name")
        case .location: String(localized: "Location")
        }
    }
}

/// Ordering and filtering for the list. Pure functions, so the rules are testable without a UI.
public enum GroupList {
    public static func arrange(
        _ groups: [AppGroup], sort: GroupSort, search: String = ""
    ) -> [AppGroup] {
        sorted(matching(visible(groups), search), by: sort)
    }

    /// Drops macOS's own folders.
    ///
    /// Two thirds of `~/Library/Caches` is `com.apple.*` -- TCC, controlcenter, akd -- and
    /// none of it belongs to an app the user installed or would recognise. Offering to move
    /// it is the same mistake as offering to move a folder the allowlist forbids.
    ///
    /// The test is "macOS's own AND nothing claims it": `com.apple.dt.Xcode` resolves to an
    /// installed Xcode.app and stays, because it is Xcode's data and the largest single win
    /// on a developer's disk.
    public static func visible(_ groups: [AppGroup]) -> [AppGroup] {
        groups.filter { !isSystemOwned($0) }
    }

    /// Apple names that are not bundle identifiers, from a real Library. The same curated
    /// shape as `AppIdentityResolver.aliases`, and for the same reason: nothing in the name
    /// itself says these belong to macOS.
    private static let systemFolderNames: Set<String> = [
        "addressbook", "apple", "callhistorydb", "callhistorytransactions",
        "knowledge", "mobilesync", "syncservices",
    ]

    static func isSystemOwned(_ group: AppGroup) -> Bool {
        // Never hide something already moved: that hides its Undo button, and with it the
        // only route back for data that is no longer where its owner expects it.
        guard group.folders.allSatisfy({ !$0.isSymlink }) else { return false }
        guard group.appURL == nil else { return false }
        return group.folders.allSatisfy { folder in
            let name = folder.name.lowercased()
            return name.hasPrefix("com.apple.") || systemFolderNames.contains(name)
        }
    }

    /// Matches the app name and the names of the folders inside it, so searching
    /// "vscode" finds the row named "Visual Studio Code" via com.microsoft.VSCode.ShipIt.
    public static func matching(_ groups: [AppGroup], _ search: String) -> [AppGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            if contains(group.displayName, query) { return true }
            return group.folders.contains {
                contains($0.name, query) || contains($0.category.rawValue, query)
                    || contains($0.category.label, query)
            }
        }
    }

    public static func sorted(_ groups: [AppGroup], by sort: GroupSort) -> [AppGroup] {
        switch sort {
        case .size:
            // Biggest first, but anything needing an administrator sinks below everything
            // that can be moved with a single click, however large it is.
            groups.sorted {
                $0.needsAdmin == $1.needsAdmin
                    ? $0.totalBytes > $1.totalBytes
                    : !$0.needsAdmin
            }
        case .name:
            groups.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .location:
            // Moved folders first -- the ones with something to undo -- then by size.
            groups.sorted {
                let left = $0.folders.contains(where: \.isSymlink)
                let right = $1.folders.contains(where: \.isSymlink)
                return left == right ? $0.totalBytes > $1.totalBytes : left
            }
        }
    }

    /// Case- and accent-insensitive, so "cafe" matches "Café".
    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
