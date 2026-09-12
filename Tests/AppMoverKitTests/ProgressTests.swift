import Testing
import Foundation
@testable import AppMoverKit

/// The handler is `@Sendable` because it crosses into a detached task in the app, so a test
/// cannot simply append to a local var.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [MoveProgress] = []

    var all: [MoveProgress] { lock.withLock { steps } }
    var fractions: [Double] { all.map(\.fraction) }
    var phases: [MovePhase] { all.map(\.phase) }

    func append(_ step: MoveProgress) { lock.withLock { steps.append(step) } }
}

@Suite("Progress reporting")
struct ProgressTests {
    /// The bar is measured against `Manifest.logicalBytes`, so ditto's own accounting has to
    /// agree with it. If a future macOS changes the wording of `-V`, this is what catches it.
    @Test("ditto's verbose byte counts add up to the manifest's logical bytes")
    func dittoBytesMatchManifest() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Counted")
        let (volume, subpath) = try box.destination("Counted")
        let expected = try Manifest.scan(source)

        let seen = Collected()
        _ = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath,
            progress: { if $0.phase == .copying { seen.append($0) } })

        // The last copying report lands on the top of the copying span, which only happens
        // when the summed "<n> bytes for" lines reach logicalBytes exactly.
        #expect(expected.logicalBytes > 0)
        #expect(seen.fractions.last == MovePhase.copying.span.upperBound)
    }

    @Test("reports every phase, never going backwards, ending at 1")
    func monotonic() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Phases")
        let (volume, subpath) = try box.destination("Phases")

        let seen = Collected()
        _ = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath, progress: { seen.append($0) })

        #expect(seen.phases.contains(.copying))
        #expect(seen.phases.contains(.verifying))
        #expect(seen.phases.contains(.linking))
        let steps = seen.fractions
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(steps.last == 1)
    }

    @Test("undo reports progress too")
    func undoReports() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Back")
        let (volume, subpath) = try box.destination("Back")
        let engine = Engine(allowlist: box.allowlist)
        let record = try engine.move(source: source, toVolume: volume, subpath: subpath)

        let seen = Collected()
        try engine.undo(record, progress: { seen.append($0) })

        #expect(seen.fractions.last == 1)
    }

    // MARK: - Parsing

    @Test("reads the byte count out of a verbose line")
    func parsesBytes() {
        #expect(DittoLine.bytes(in: "7 bytes for ./a/f5.txt") == 7)
        #expect(DittoLine.bytes(in: "1024 bytes for ./with space.txt") == 1024)
    }

    @Test("a line that is not a byte count is not read as one",
          arguments: [">>> Copying /tmp/src ", "copying file ./a.txt ... ",
                      "linked ./a/link.txt", "ditto: /x: Permission denied"])
    func rejectsOtherLines(line: String) {
        #expect(DittoLine.bytes(in: line) == nil)
    }

    @Test("an error line is not mistaken for narration")
    func errorIsNotNarration() {
        #expect(DittoLine.isNarration("ditto: /x: Permission denied") == false)
        #expect(DittoLine.isNarration("copying file ./a.txt ... "))
        #expect(DittoLine.isNarration("7 bytes for ./a.txt"))
    }

    @Test("a failing copy reports ditto's error, not its narration")
    func failureKeepsTheError() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Missing")
        let (volume, subpath) = try box.destination("Missing")
        try FileManager.default.removeItem(at: source.appending(path: "file 0.txt"))
        // Unreadable source: ditto fails partway and its stderr is what must surface.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: source.path)
        }

        var reported = ""
        #expect(throws: EngineError.self) {
            do {
                try Engine(allowlist: box.allowlist).move(
                    source: source, toVolume: volume, subpath: subpath)
            } catch {
                reported = error.localizedDescription
                throw error
            }
        }
        // ditto's own words, not its narration. If a future macOS reworded `-V`, every line
        // would look like an error, the eight-line cap would fill with narration and the
        // real message would be dropped off the front -- which is what this catches.
        #expect(reported.contains("ditto:"))
        #expect(reported.contains("copying file") == false)
    }
}
