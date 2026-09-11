import Foundation

/// Which folders may be relocated.
///
/// Settings choose which *categories* are active, but nothing in settings can widen what is
/// permissible: the blocklist and the direct-child-only rule below are fixed. A free-form
/// folder picker would be a footgun -- choosing `~` would make `~/Library` a direct child
/// and therefore movable.
public struct Allowlist: Sendable {
    public let roots: [URL]
    private let library: URL
    private let home: URL

    public init(home: URL = URL(filePath: NSHomeDirectory()),
                categories: [FolderCategory] = FolderCategory.dataCategories) {
        self.home = home
        self.library = home.appending(path: "Library")
        self.roots = categories.map { $0.sourceRoot(home: home) }
    }

    public init(home: URL = URL(filePath: NSHomeDirectory()), settings: Settings) {
        self.init(home: home, categories: settings.activeCategories)
    }

    /// Never relocatable, regardless of settings.
    private var blocked: [URL] {
        [
            library.appending(path: "Containers"),        // sandboxd denies the redirect
            library.appending(path: "Group Containers"),
            library.appending(path: "Keychains"),
            Ledger.directory(library: library),           // our own ledger
        ]
    }

    public func check(_ candidate: URL) throws {
        // Resolve the PARENT only, never the leaf. Resolving the leaf would follow a folder
        // we have already moved out to its external target, putting it outside every root and
        // reporting "not allowed" when the truth is "already moved".
        let standardized = candidate.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let path = parent.appending(path: standardized.lastPathComponent).path

        for bad in blocked where path == bad.path || path.hasPrefix(bad.path + "/") {
            throw EngineError.blockedPath(
                reason: "\(bad.lastPathComponent) is managed by macOS and cannot be relocated safely.")
        }
        if isSIPProtected(standardized) {
            throw EngineError.blockedPath(
                reason: "\(standardized.lastPathComponent) is protected by macOS and cannot be moved.")
        }
        for root in roots where path == resolved(root) {
            throw EngineError.blockedPath(
                reason: "Move a folder inside \(root.lastPathComponent), not \(root.lastPathComponent) itself.")
        }
        // Direct children only: no descending into a root and moving something deep.
        guard let root = roots.first(where: { path.hasPrefix(resolved($0) + "/") }) else {
            throw EngineError.blockedPath(
                reason: "\(standardized.lastPathComponent) is not in a folder AppMover manages.")
        }
        guard path == resolved(root) + "/" + standardized.lastPathComponent else {
            throw EngineError.blockedPath(
                reason: "Only folders directly inside \(root.lastPathComponent) can be moved.")
        }
    }

    public func isAllowed(_ candidate: URL) -> Bool { (try? check(candidate)) != nil }

    private func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// System Integrity Protection marks its files restricted; moving them fails even as root.
    private func isSIPProtected(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_RESTRICTED) != 0
    }
}
