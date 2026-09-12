import Testing
import Foundation
@testable import AppMoverKit

@Suite("Destination stays on the chosen volume")
struct DestinationEscapeTests {
    @Test("refuses a subpath that climbs out of the volume with ..")
    func rejectsParentTraversal() throws {
        // Arrange
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Escape")
        let (volume, subpath) = try box.destination("Escape")
        let climbing = "../" + subpath

        // Act / Assert
        #expect(throws: EngineError.self) {
            try Engine(allowlist: box.allowlist).move(
                source: source, toVolume: volume, subpath: climbing)
        }
        // The original is untouched: this must fail before anything is copied or renamed.
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "file 0.txt").path))
    }

    @Test("refuses a . component too")
    func rejectsDotComponent() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Dot")
        let (volume, subpath) = try box.destination("Dot")

        #expect(throws: EngineError.self) {
            try Engine(allowlist: box.allowlist).move(
                source: source, toVolume: volume, subpath: "./" + subpath)
        }
    }
}

@Suite("Orphan repair")
struct OrphanRepairTests {
    /// Reproduces what a Sparkle update does: write a new folder aside, rename() it over the
    /// old path. The symlink is destroyed and a real directory stands where it was.
    func orphan(_ box: Sandbox, named name: String) throws -> MoveRecord {
        let source = try box.makeFolder(name)
        let (volume, subpath) = try box.destination(name)
        let record = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath)
        try FileManager.default.removeItem(at: source)          // the link
        try FileManager.default.createDirectory(
            at: source, withIntermediateDirectories: true)
        try "fresh".write(to: source.appending(path: "new.txt"),
                          atomically: true, encoding: .utf8)
        return record
    }

    @Test("removes the abandoned external copy and leaves the live folder alone")
    func discardsTheAbandonedCopy() throws {
        // Arrange
        let box = try Sandbox(); defer { box.cleanup() }
        let record = try orphan(box, named: "Sparkle")
        let target = try #require(record.currentTarget())
        #expect(Ledger.health(of: record) == .orphaned)

        // Act
        try Engine(allowlist: box.allowlist).discardOrphan(record)

        // Assert
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try String(contentsOf: record.sourceURL.appending(path: "new.txt"),
                           encoding: .utf8) == "fresh")
    }

    @Test("refuses when the link is in fact live, so it cannot delete the only copy")
    func refusesAHealthyLink() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Healthy")
        let (volume, subpath) = try box.destination("Healthy")
        let record = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath)

        #expect(throws: EngineError.notOrphaned(record.sourceURL)) {
            try Engine(allowlist: box.allowlist).discardOrphan(record)
        }
        // The data the live link points at is still there.
        #expect(try String(contentsOf: source.appending(path: "file 0.txt"), encoding: .utf8)
                == "content-0")
    }

    @Test("never removes sibling folders moved to the same drive")
    func leavesSiblingsAlone() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let keeper = try box.makeFolder("Keeper")
        let (volume, keeperPath) = try box.destination("Keeper")
        let keeperRecord = try Engine(allowlist: box.allowlist).move(
            source: keeper, toVolume: volume, subpath: keeperPath)
        let record = try orphan(box, named: "Sparkle")

        try Engine(allowlist: box.allowlist).discardOrphan(record)

        #expect(FileManager.default.fileExists(
            atPath: try #require(keeperRecord.currentTarget()).path))
    }
}

/// The directory enumerator spells paths differently from the ones the test built.
private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

@Suite("Interrupted runs are visible")
struct StrandedBackupTests {
    @Test("finds a backup left by a run that died between the rename and the symlink")
    func findsStrandedBackups() throws {
        // Arrange
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Interrupted")
        let stranded = URL(filePath: source.path + ".appmover.bak")
        try FileManager.default.moveItem(at: source, to: stranded)

        // Act
        let found = SpaceScanner(home: box.home).strandedBackups()

        // Assert: compare resolved paths -- the enumerator hands back /private/var and a
        // trailing slash, which are the same folder spelled differently.
        #expect(found.map(resolved) == [resolved(stranded)])
    }

    @Test("finds a partial restore left by an interrupted undo")
    func findsStrandedRestores() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("HalfUndone")
        let stranded = URL(filePath: source.path + ".appmover.restore")
        try FileManager.default.moveItem(at: source, to: stranded)

        #expect(SpaceScanner(home: box.home).strandedBackups().map(resolved)
                == [resolved(stranded)])
    }

    @Test("reports nothing when no run was interrupted")
    func findsNothingNormally() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFolder("Normal")

        #expect(SpaceScanner(home: box.home).strandedBackups().isEmpty)
    }
}
