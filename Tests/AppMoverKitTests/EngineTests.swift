import Testing
import Foundation
@testable import AppMoverKit

/// A throwaway home directory with the allowlisted roots, on the real filesystem.
struct Sandbox {
    let home: URL
    let allowlist: Allowlist

    init() throws {
        home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "appmover-tests/\(UUID().uuidString)")
        allowlist = Allowlist(home: home)
        for root in allowlist.roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    var appSupport: URL { home.appending(path: "Library/Application Support") }

    /// A folder with nested dirs, a space in a name, an xattr and an inner symlink.
    @discardableResult
    func makeFolder(_ name: String, files: Int = 3) throws -> URL {
        let dir = appSupport.appending(path: name)
        try FileManager.default.createDirectory(
            at: dir.appending(path: "nested dir"), withIntermediateDirectories: true)
        for i in 0..<files {
            try "content-\(i)".write(to: dir.appending(path: "file \(i).txt"),
                                     atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(
            at: dir.appending(path: "inner-link"),
            withDestinationURL: dir.appending(path: "file 0.txt"))
        return dir
    }

    /// Destination on the same physical volume, expressed the way Engine expects.
    func destination(_ name: String) throws -> (Volume, String) {
        let volume = try #require(Volume.containing(home))
        let full = home.appending(path: "external/\(name)")
        let mount = volume.mountPoint.path == "/" ? "" : volume.mountPoint.path
        let subpath = String(full.path.dropFirst(mount.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        return (volume, subpath)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

@Suite("Manifest")
struct ManifestTests {
    @Test("counts every entry and sums logical bytes, not allocated blocks")
    func scansTree() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let dir = try box.makeFolder("App", files: 3)

        let manifest = try Manifest.scan(dir)

        // 3 files + "nested dir" + "inner-link"
        #expect(manifest.entryCount == 5)
        #expect(manifest.logicalBytes == 9 * 3)   // "content-N" is 9 bytes
    }

    @Test("counts hidden files, since dotfiles are real app state")
    func includesHidden() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let dir = try box.makeFolder("App", files: 1)
        try "x".write(to: dir.appending(path: ".hidden"), atomically: true, encoding: .utf8)

        #expect(try Manifest.scan(dir).entryCount == 4)
    }
}

@Suite("Allowlist")
struct AllowlistTests {
    @Test("permits a folder inside an allowlisted root")
    func allowsChild() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        #expect(box.allowlist.isAllowed(box.appSupport.appending(path: "Code")))
    }

    @Test("blocks sandbox containers, which break when their path is redirected",
          arguments: ["Containers/com.apple.Notes", "Group Containers/group.com.apple.notes"])
    func blocksContainers(path: String) throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let target = box.home.appending(path: "Library/\(path)")
        #expect(!box.allowlist.isAllowed(target))
        #expect(throws: EngineError.self) { try box.allowlist.check(target) }
    }

    @Test("blocks the roots themselves, which carry ACLs and are structural")
    func blocksRoots() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        for root in box.allowlist.roots {
            #expect(!box.allowlist.isAllowed(root))
        }
    }

    @Test("blocks its own ledger directory")
    func blocksLedger() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        #expect(!box.allowlist.isAllowed(box.appSupport.appending(path: "AppMover")))
    }

    @Test("blocks paths outside the allowlist entirely")
    func blocksOutside() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        #expect(!box.allowlist.isAllowed(box.home.appending(path: "Documents/Taxes")))
        #expect(!box.allowlist.isAllowed(URL(filePath: "/System/Library")))
    }

    @Test("cannot be escaped with a relative traversal")
    func blocksTraversal() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let sneaky = box.appSupport.appending(path: "../Containers/com.apple.Notes")
        #expect(!box.allowlist.isAllowed(sneaky))
    }
}
