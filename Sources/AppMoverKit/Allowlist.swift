import Foundation

/// Which folders may be relocated.
///
/// A free-form picker over ~/Library is a footgun, so v1 permits only direct children of a
/// few known-safe roots. Sandbox containers are blocked outright: TCC denies reads, and even
/// with Full Disk Access a sandboxed app's profile grants the *literal* container path, so
/// sandboxd denies the redirect and the app breaks.
public struct Allowlist: Sendable {
    public let roots: [URL]
    private let library: URL

    public init(home: URL = URL(filePath: NSHomeDirectory())) {
        self.library = home.appending(path: "Library")
        self.roots = [
            library.appending(path: "Application Support"),
            library.appending(path: "Caches"),
            library.appending(path: "Developer"),
        ]
    }

    /// Paths that must never be relocated, checked before the allowlist.
    private var blocked: [URL] {
        [
            library.appending(path: "Containers"),
            library.appending(path: "Group Containers"),
            library.appending(path: "Keychains"),
            Ledger.directory(library: library),
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
                reason: "\(bad.lastPathComponent) is managed by macOS and cannot be relocated safely."
            )
        }
        // The roots themselves carry ACLs and are structural; only their children may move.
        for root in roots where path == root.standardizedFileURL.resolvingSymlinksInPath().path {
            throw EngineError.blockedPath(
                reason: "Move a folder inside \(root.lastPathComponent), not \(root.lastPathComponent) itself."
            )
        }
        guard roots.contains(where: {
            path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }) else {
            throw EngineError.blockedPath(
                reason: "Only folders inside Application Support, Caches, or Developer can be moved."
            )
        }
    }

    public func isAllowed(_ candidate: URL) -> Bool {
        (try? check(candidate)) != nil
    }
}
