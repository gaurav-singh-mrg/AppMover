import Foundation

extension String {
    /// Keeps alphanumerics, lowercased -- Pearcleaner's `pearFormat`.
    ///
    /// This is what separates most folder names from the app that owns them: "Boom 3D" the app
    /// writes "Boom3D", "Arduino IDE" writes "arduino-ide". Falls back to the lowercased
    /// original when nothing survives, so a folder named "---" never keys on "".
    var squashed: String {
        let kept = unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let result = String(String.UnicodeScalarView(kept)).lowercased()
        return result.isEmpty ? lowercased() : result
    }
}

/// Resolves folders to the app they belong to, so `com.microsoft.VSCode.ShipIt` in Caches
/// can sit in the same row as the app that owns it.
///
/// Builds one map of bundle identifier -> app up front rather than asking LaunchServices per
/// folder. Immutable once built, so it stays Sendable.
///
/// Pearcleaner solves the mirror-image problem -- given one app, sweep ~70 hardcoded Library
/// paths and keep every child whose name matches any identifier of that app -- and can afford
/// loose matching because a folder claimed by two apps just appears in both lists. Here a
/// folder gets exactly one row, so a wrong match silently merges two unrelated apps. Every
/// tier below is therefore unique-or-nothing, and only the tiers that measurably resolved
/// something on a real Library are present: letters-only and bundle-id-suffix matching
/// resolved zero folders, and "app name starts with the folder name" was wrong six times out
/// of eight (Xcode -> Xcodes, Claude -> Claude Code URL Handler, Music -> MusicBrainz Picard).
public struct AppIdentityResolver: AppIdentityResolving {
    private let byBundleID: [String: URL]
    private let byName: [String: URL]      // squashed app name -> app, collisions removed
    private let names: [(key: String, url: URL)]

    /// Folders whose name shares nothing with the app that owns them, so no heuristic reaches
    /// them. Pearcleaner keeps a ~260-line `conditions` table for this; these are the cases
    /// that show up under the four roots AppMover scans. The alias also groups the folders
    /// together when the app is not installed at all -- Xcode's four `~/Library/Developer`
    /// folders become one row rather than four.
    ///
    /// ponytail: an alias names the app whether or not it is installed, so a "Code" folder is
    /// labelled "Visual Studio Code" on the table's word alone. Right in practice -- the forks
    /// write Cursor, VSCodium, Windsurf -- but the ceiling is that only a folder nobody else
    /// claims belongs here. Read the folder's own contents if that ever stops holding.
    private static let aliases: [String: (bundleID: String, displayName: String)] = [
        "code": ("com.microsoft.vscode", "Visual Studio Code"),
        "xcode": ("com.apple.dt.xcode", "Xcode"),
        "coresimulator": ("com.apple.dt.xcode", "Xcode"),
        "xctestdevices": ("com.apple.dt.xcode", "Xcode"),
        "dvtdownloads": ("com.apple.dt.xcode", "Xcode"),
    ]

    /// Shorter than this, a prefix match is noise: "Code" must not claim "CodeRunner".
    private static let minimumPrefixLength = 5

    public init(searchPaths: [URL] = [
        URL(filePath: "/Applications"),
        URL(filePath: NSHomeDirectory()).appending(path: "Applications"),
    ]) {
        var bundles: [String: URL] = [:]
        var byName: [String: URL] = [:]
        var ambiguous: Set<String> = []
        let fm = FileManager.default

        for root in searchPaths {
            let contents = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for app in contents where app.pathExtension == "app" {
                let key = app.deletingPathExtension().lastPathComponent.squashed
                // Two different apps squashing to one key would merge their data into a single
                // row, picked by directory order. Drop the key instead: unresolved is already
                // a correct outcome, a wrong merge is not.
                if let existing = byName[key], existing != app { ambiguous.insert(key) }
                byName[key] = app
                if let plist = NSDictionary(
                    contentsOf: app.appending(path: "Contents/Info.plist")),
                   let id = plist["CFBundleIdentifier"] as? String {
                    bundles[id.lowercased()] = app
                }
            }
        }
        for key in ambiguous { byName.removeValue(forKey: key) }
        self.byBundleID = bundles
        self.byName = byName
        self.names = byName.map { (key: $0.key, url: $0.value) }
    }

    public func identity(for folder: FolderSize) -> AppIdentity {
        // The app bundle itself.
        if folder.url.pathExtension == "app" {
            let name = folder.url.deletingPathExtension().lastPathComponent
            return AppIdentity(key: name.squashed, displayName: name, appURL: folder.url)
        }
        let squashed = folder.name.squashed

        // Curated first: it is the only evidence for these folders, and it beats a heuristic.
        if let alias = Self.aliases[squashed] {
            return AppIdentity(key: alias.displayName.squashed,
                               displayName: alias.displayName,
                               appURL: byBundleID[alias.bundleID])
        }
        // A bundle identifier, possibly with an updater suffix like ".ShipIt".
        if let app = matchBundleID(folder.name) { return identity(app) }
        // The app's name, with spaces and punctuation ignored on both sides.
        if let app = byName[squashed] { return identity(app) }
        // "Telegram Desktop" -> Telegram.app. Only when exactly one app claims it.
        if let app = matchPrefix(squashed) { return identity(app) }

        // Nothing found. Key on the folder's own name so it keeps its own row rather than
        // collapsing into a shared bucket with every other unidentified folder.
        return AppIdentity(key: squashed, displayName: folder.name)
    }

    private func identity(_ app: URL) -> AppIdentity {
        let name = app.deletingPathExtension().lastPathComponent
        return AppIdentity(key: name.squashed, displayName: name, appURL: app)
    }

    /// "com.microsoft.VSCode.ShipIt" -> "com.microsoft.VSCode" -> ... until something matches.
    private func matchBundleID(_ name: String) -> URL? {
        guard name.contains(".") else { return nil }
        var parts = name.lowercased().split(separator: ".")
        while parts.count >= 2 {
            if let app = byBundleID[parts.joined(separator: ".")] { return app }
            parts.removeLast()
        }
        return nil
    }

    /// ponytail: linear over the installed apps, ~60 of them, once per folder. An index keyed
    /// on prefixes would be faster and is worth it only if app counts reach the thousands.
    private func matchPrefix(_ squashed: String) -> URL? {
        let candidates = names.filter {
            $0.key.count >= Self.minimumPrefixLength && squashed.hasPrefix($0.key)
        }
        return candidates.count == 1 ? candidates[0].url : nil
    }
}
