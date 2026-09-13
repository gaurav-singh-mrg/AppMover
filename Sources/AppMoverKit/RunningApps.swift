import Foundation

/// A running application, reduced to what identifies it on disk.
///
/// Plain values rather than `NSRunningApplication`, so the matching rules below stay in the
/// Kit and stay testable without AppKit. The app target supplies the adapter.
public struct RunningApp: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let bundlePath: String?

    public init(pid: Int32, bundleID: String?, bundlePath: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.bundlePath = bundlePath
    }

    /// "/Applications/Visual Studio Code.app" -> "Visual Studio Code"
    var bundleName: String? {
        bundlePath.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
    }

    public var displayName: String { bundleName ?? bundleID ?? String(localized: "another app") }
}

/// Decides whether a folder belongs to an app that is running right now.
///
/// Moving a running app's data is the one unrecoverable failure this app can cause, and
/// nothing downstream detects it: `ditto` copies a torn snapshot, the rename leaves the
/// app's open descriptors pointing at inodes that are about to be unlinked, and every write
/// it makes from then on is discarded when it quits. The copy verifies, the link resolves,
/// the ledger reads healthy. So this refuses the move rather than warning about it.
public enum RunningAppCheck {
    /// Names of running apps that own any of `folderNames`, or the bundle at `appPath`.
    ///
    /// Deliberately eager: a false block costs the user a "quit it first", a false pass
    /// costs them their data.
    public static func blockers(
        folderNames: [String], appPath: String? = nil, running: [RunningApp]
    ) -> [String] {
        let names = Set(folderNames.map { $0.lowercased() })
        let bundleIDs = Set(folderNames.flatMap(bundleIDCandidates))
        let wantedPath = appPath.map(normalized)

        let blocking = running.filter { app in
            // The app bundle this row resolved to is running.
            if let wantedPath, let path = app.bundlePath, normalized(path) == wantedPath {
                return true
            }
            // A folder named for its bundle id, with or without an updater suffix.
            if let id = app.bundleID, bundleIDs.contains(id.lowercased()) { return true }
            // A folder named for the app itself, as Application Support usually is.
            if let name = app.bundleName, names.contains(name.lowercased()) { return true }
            return false
        }
        // De-duplicated: an app with several processes must not repeat in the message.
        return Set(blocking.map(\.displayName)).sorted()
    }

    /// "com.microsoft.VSCode.ShipIt" -> ["com.microsoft.vscode.shipit", "com.microsoft.vscode",
    /// "com.microsoft"], so an updater's cache folder still resolves to the app that owns it.
    static func bundleIDCandidates(_ name: String) -> [String] {
        guard name.contains(".") else { return [] }
        var parts = name.lowercased().split(separator: ".")
        var candidates: [String] = []
        while parts.count >= 2 {
            candidates.append(parts.joined(separator: "."))
            parts.removeLast()
        }
        return candidates
    }

    /// Compare resolved paths, never URLs: /private prefixes and trailing slashes differ
    /// between what NSWorkspace reports and what the scanner built.
    private static func normalized(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
