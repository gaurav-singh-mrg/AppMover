import Foundation

/// Entry count + summed logical bytes for a directory tree.
///
/// Deliberately NOT `du`. `du` reports allocated blocks, which drift across volumes with
/// block size and APFS compression -- measured 1.8% on a real 559MB folder, enough to fail
/// verification on a perfectly good copy and roll it back.
public struct Manifest: Equatable, Sendable {
    public let entryCount: Int
    public let logicalBytes: Int64

    public init(entryCount: Int, logicalBytes: Int64) {
        self.entryCount = entryCount
        self.logicalBytes = logicalBytes
    }

    /// Walks `url` without following symlinks; inner symlinks are counted, not traversed.
    ///
    /// The ROOT is resolved first: FileManager's enumerator will not descend through a
    /// symlink handed to it as the root, so scanning a folder we have already moved would
    /// otherwise report an empty tree and look like catastrophic data loss.
    public static func scan(_ url: URL) throws -> Manifest {
        let root = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []   // no skipsHiddenFiles: dotfiles are app state and must be counted
        ) else {
            throw EngineError.notADirectory(url)
        }

        var count = 0
        var bytes: Int64 = 0
        for case let child as URL in walker {
            count += 1
            let values = try? child.resourceValues(forKeys: keys)
            if values?.isRegularFile == true, let size = values?.fileSize {
                bytes += Int64(size)
            }
        }
        return Manifest(entryCount: count, logicalBytes: bytes)
    }
}
