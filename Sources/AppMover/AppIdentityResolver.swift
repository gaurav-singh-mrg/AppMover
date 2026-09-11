import AppKit
import AppMoverKit

/// Resolves folders to the app they belong to, so `com.microsoft.VSCode.ShipIt` in Caches
/// can sit in the same row as the app that owns it.
///
/// Builds one map of bundle identifier -> app up front rather than asking LaunchServices per
/// folder. Immutable once built, so it stays Sendable.
struct AppIdentityResolver: AppIdentityResolving {
    private let byBundleID: [String: URL]
    private let byName: [String: URL]

    init(searchPaths: [URL] = [
        URL(filePath: "/Applications"),
        URL(filePath: NSHomeDirectory()).appending(path: "Applications"),
    ]) {
        var bundles: [String: URL] = [:]
        var names: [String: URL] = [:]
        let fm = FileManager.default

        for root in searchPaths {
            let contents = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for app in contents where app.pathExtension == "app" {
                names[app.deletingPathExtension().lastPathComponent.lowercased()] = app
                if let plist = NSDictionary(
                    contentsOf: app.appending(path: "Contents/Info.plist")),
                   let id = plist["CFBundleIdentifier"] as? String {
                    bundles[id.lowercased()] = app
                }
            }
        }
        self.byBundleID = bundles
        self.byName = names
    }

    func identity(for folder: FolderSize) -> AppIdentity {
        // The app bundle itself.
        if folder.url.pathExtension == "app" {
            let name = folder.url.deletingPathExtension().lastPathComponent
            return AppIdentity(key: name.lowercased(), displayName: name, appURL: folder.url)
        }
        // A bundle identifier, possibly with an updater suffix like ".ShipIt".
        if let app = matchBundleID(folder.name) {
            let name = app.deletingPathExtension().lastPathComponent
            return AppIdentity(key: name.lowercased(), displayName: name, appURL: app)
        }
        // A plain name. Key on the name either way, so folders with the same name group
        // whether or not an app was found -- an unresolved folder keeps its own row.
        let key = folder.name.lowercased()
        return AppIdentity(key: key, displayName: folder.name, appURL: byName[key])
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
}
