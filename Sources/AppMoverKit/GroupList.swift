import Foundation

public enum GroupSort: String, Codable, CaseIterable, Sendable, Identifiable {
    case size
    case name
    case location

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .location: "Location"
        }
    }
}

/// Ordering and filtering for the list. Pure functions, so the rules are testable without a UI.
public enum GroupList {
    public static func arrange(
        _ groups: [AppGroup], sort: GroupSort, search: String = ""
    ) -> [AppGroup] {
        sorted(matching(groups, search), by: sort)
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
            }
        }
    }

    public static func sorted(_ groups: [AppGroup], by sort: GroupSort) -> [AppGroup] {
        switch sort {
        case .size:
            groups.sorted { $0.totalBytes > $1.totalBytes }
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
