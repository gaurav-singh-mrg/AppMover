import Testing
import Foundation
@testable import AppMoverKit

@Suite("Move and undo")
struct MoveTests {
    @Test("replaces the folder with a symlink that reads through to the new location")
    func movesAndLinks() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Feishin")
        let (volume, subpath) = try box.destination("Feishin")
        let engine = Engine(allowlist: box.allowlist)

        let record = try engine.move(source: source, toVolume: volume, subpath: subpath)

        let link = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        #expect(link == record.currentTarget()?.path)
        #expect(try String(contentsOf: source.appending(path: "file 0.txt"), encoding: .utf8)
                == "content-0")
        #expect(record.sizeBytes == 27)
    }

    @Test("preserves extended attributes across the move")
    func preservesXattrs() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Xattr")
        let file = source.appending(path: "file 0.txt")
        try setXattr("com.test.state", value: "important", on: file)
        let (volume, subpath) = try box.destination("Xattr")

        _ = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath)

        #expect(getXattr("com.test.state", on: file) == "important")
    }

    @Test("keeps inner symlinks as symlinks rather than flattening them into copies")
    func preservesInnerSymlinks() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Inner")
        let (volume, subpath) = try box.destination("Inner")

        _ = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath)

        let inner = source.appending(path: "inner-link").path
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: inner)) != nil)
    }

    @Test("undo restores a real directory and removes the external copy")
    func undoRoundtrip() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Roundtrip")
        let before = try Manifest.scan(source)
        let (volume, subpath) = try box.destination("Roundtrip")
        let engine = Engine(allowlist: box.allowlist)

        let record = try engine.move(source: source, toVolume: volume, subpath: subpath)
        let target = try #require(record.currentTarget())
        try engine.undo(record)

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: source.path)) == nil)
        #expect(try Manifest.scan(source) == before)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("undo refuses when the external volume is not mounted")
    func undoNeedsTarget() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Dangling")
        let (volume, subpath) = try box.destination("Dangling")
        let engine = Engine(allowlist: box.allowlist)
        let record = try engine.move(source: source, toVolume: volume, subpath: subpath)

        // simulate an unplugged drive
        try FileManager.default.removeItem(at: #require(record.currentTarget()))

        #expect(throws: EngineError.self) { try engine.undo(record) }
        // the symlink is left alone, so reconnecting the drive still recovers
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: source.path)) != nil)
    }
}

@Suite("Aborts leave the source untouched")
struct AbortTests {
    @Test("refuses a folder that is already a symlink")
    func refusesDoubleMove() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Twice")
        let (volume, subpath) = try box.destination("Twice")
        let engine = Engine(allowlist: box.allowlist)
        _ = try engine.move(source: source, toVolume: volume, subpath: subpath)

        #expect(throws: EngineError.alreadyLinked(source)) {
            _ = try engine.move(source: source, toVolume: volume, subpath: subpath + "-again")
        }
    }

    @Test("refuses when the destination already exists, keeping the source intact")
    func refusesExistingDestination() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Existing")
        let (volume, subpath) = try box.destination("Existing")
        try FileManager.default.createDirectory(
            at: volume.mountPoint.appending(path: subpath), withIntermediateDirectories: true)

        #expect(throws: EngineError.self) {
            _ = try Engine(allowlist: box.allowlist).move(
                source: source, toVolume: volume, subpath: subpath)
        }
        #expect(try Manifest.scan(source).entryCount == 5)
    }

    @Test("refuses when a previous run left a backup behind")
    func refusesStaleBackup() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Stale")
        try FileManager.default.createDirectory(
            at: URL(filePath: source.path + ".appmover.bak"), withIntermediateDirectories: true)
        let (volume, subpath) = try box.destination("Stale")

        #expect(throws: EngineError.self) {
            _ = try Engine(allowlist: box.allowlist).move(
                source: source, toVolume: volume, subpath: subpath)
        }
        #expect(try Manifest.scan(source).entryCount == 5)
    }

    @Test("refuses a blocked path before copying anything")
    func refusesBlockedPath() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let container = box.home.appending(path: "Library/Containers/com.apple.Notes")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let (volume, subpath) = try box.destination("Blocked")

        #expect(throws: EngineError.self) {
            _ = try Engine(allowlist: box.allowlist).move(
                source: container, toVolume: volume, subpath: subpath)
        }
        #expect(!FileManager.default.fileExists(
            atPath: volume.mountPoint.appending(path: subpath).path))
    }
}

// MARK: - xattr helpers

func setXattr(_ name: String, value: String, on url: URL) throws {
    let data = Array(value.utf8)
    let result = url.withUnsafeFileSystemRepresentation { path in
        setxattr(path, name, data, data.count, 0, 0)
    }
    #expect(result == 0)
}

func getXattr(_ name: String, on url: URL) -> String? {
    url.withUnsafeFileSystemRepresentation { path -> String? in
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}

@Suite("Destination integrity")
struct DestinationTests {
    @Test("refuses a destination that is itself a symlink, which would verify the wrong tree")
    func refusesSymlinkDestination() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Real")
        let decoy = try box.makeFolder("Decoy")          // different contents, same shape
        try "extra".write(to: decoy.appending(path: "extra.txt"),
                          atomically: true, encoding: .utf8)

        let (volume, subpath) = try box.destination("Trap")
        let trap = volume.mountPoint.appending(path: subpath)
        try FileManager.default.createDirectory(
            at: trap.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: trap, withDestinationURL: decoy)

        #expect(throws: EngineError.self) {
            _ = try Engine(allowlist: box.allowlist).move(
                source: source, toVolume: volume, subpath: subpath)
        }
        // the source must be untouched, and the decoy must not have been clobbered
        #expect(try Manifest.scan(source).entryCount == 5)
        #expect(try Manifest.scan(decoy).entryCount == 6)
    }
}

extension DestinationTests {
    @Test("refuses a dangling symlink at the destination, which fileExists reports as absent")
    func refusesDanglingSymlinkDestination() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Src")
        let (volume, subpath) = try box.destination("Dangler")
        let trap = volume.mountPoint.appending(path: subpath)
        try FileManager.default.createDirectory(
            at: trap.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: trap, withDestinationURL: box.home.appending(path: "gone"))

        #expect(throws: EngineError.self) {
            _ = try Engine(allowlist: box.allowlist).move(
                source: source, toVolume: volume, subpath: subpath)
        }
        #expect(try Manifest.scan(source).entryCount == 5)
    }
}

extension DestinationTests {
    @Test("undo never removes sibling folders moved to the same drive")
    func undoKeepsSiblings() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let first = try box.makeFolder("First")
        let second = try box.makeFolder("Second")
        let engine = Engine(allowlist: box.allowlist)

        let (volume, subA) = try box.destination("shared/First")
        let (_, subB) = try box.destination("shared/Second")
        let recordA = try engine.move(source: first, toVolume: volume, subpath: subA)
        _ = try engine.move(source: second, toVolume: volume, subpath: subB)

        try engine.undo(recordA)

        // Second is still moved out, and its data is still on the drive
        let secondTarget = volume.mountPoint.appending(path: subB)
        #expect(FileManager.default.fileExists(atPath: secondTarget.path))
        #expect(try Manifest.scan(second).entryCount == 5)
    }
}
