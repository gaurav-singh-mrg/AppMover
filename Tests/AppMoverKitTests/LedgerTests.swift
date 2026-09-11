import Testing
import Foundation
@testable import AppMoverKit

@Suite("Ledger")
struct LedgerTests {
    func sample(_ name: String) -> MoveRecord {
        MoveRecord(source: "/Users/x/Library/Application Support/\(name)",
                   volumeUUID: "UUID-1", relativePath: "AppMover/\(name)",
                   movedAt: Date(timeIntervalSince1970: 1_700_000_000), sizeBytes: 1024)
    }

    @Test("adding returns a new ledger and never mutates the original")
    func addingIsImmutable() {
        let original = Ledger()
        let updated = original.adding(sample("Code"))

        #expect(original.links.isEmpty)
        #expect(updated.links.count == 1)
    }

    @Test("adding the same source twice replaces rather than duplicates")
    func addingDeduplicates() {
        let ledger = Ledger().adding(sample("Code")).adding(sample("Code"))
        #expect(ledger.links.count == 1)
    }

    @Test("removing drops only the named source")
    func removing() {
        let ledger = Ledger().adding(sample("Code")).adding(sample("Slack"))
        let after = ledger.removing(source: sample("Code").source)

        #expect(after.links.count == 1)
        #expect(after.links.first?.displayName == "Slack")
        #expect(ledger.links.count == 2)   // original untouched
    }

    @Test("survives a save/load roundtrip")
    func roundtrip() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = Ledger().adding(sample("Code"))

        try ledger.save(to: url)

        #expect(Ledger.load(from: url) == ledger)
    }

    @Test("a missing or corrupt file loads as empty rather than throwing")
    func toleratesBadFile() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(Ledger.load(from: url).links.isEmpty)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(Ledger.load(from: url).links.isEmpty)
    }

    @Test("reports volumeMissing when the drive is not mounted")
    func healthWithoutVolume() {
        let ledger = Ledger().adding(sample("Code"))
        #expect(ledger.health(of: sample("Code")) == .volumeMissing)
    }

    @Test("reports healthy for a link that resolves to a real directory")
    func healthWhenLinked() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Healthy")
        let (volume, subpath) = try box.destination("Healthy")
        let record = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath)

        #expect(Ledger().adding(record).health(of: record) == .healthy)
    }
}

@Suite("Grouping")
struct AppGroupTests {
    func folder(_ name: String, _ category: FolderCategory, bytes: Int64) -> FolderSize {
        FolderSize(url: category.sourceRoot().appending(path: name), bytes: bytes,
                   category: category, isSymlink: false, needsAdmin: false)
    }

    @Test("puts an app's Application Support and Caches in one row")
    func groupsByName() {
        let groups = AppGroup.group([
            folder("Google", .applicationSupport, bytes: 2_000),
            folder("Google", .caches, bytes: 1_000),
        ], using: NameIdentityResolver())

        #expect(groups.count == 1)
        #expect(groups[0].totalBytes == 3_000)
        #expect(groups[0].categorySummary == "Application Support · Caches")
    }

    @Test("every folder lands in exactly one row and sizes sum exactly")
    func losesNothing() {
        let input = [
            folder("Google", .applicationSupport, bytes: 2_000),
            folder("Google", .caches, bytes: 1_000),
            folder("Code", .applicationSupport, bytes: 4_000),
            folder("ms-playwright", .caches, bytes: 2_500),
            folder("Xcode", .developer, bytes: 15_000),
        ]

        let groups = AppGroup.group(input, using: NameIdentityResolver())

        let regrouped = groups.flatMap(\.folders)
        #expect(regrouped.count == input.count)
        #expect(Set(regrouped.map(\.id)) == Set(input.map(\.id)))
        #expect(groups.reduce(0) { $0 + $1.totalBytes } == input.reduce(0) { $0 + $1.bytes })
    }

    @Test("unidentifiable folders keep their own row instead of sharing a bucket")
    func doesNotCollapseUnknowns() {
        let groups = AppGroup.group([
            folder("weird-thing-1", .caches, bytes: 10),
            folder("weird-thing-2", .caches, bytes: 20),
        ], using: NameIdentityResolver())

        #expect(groups.count == 2)
    }

    @Test("rows are ordered by total size, largest first")
    func sortsBySize() {
        let groups = AppGroup.group([
            folder("Small", .caches, bytes: 10),
            folder("Big", .applicationSupport, bytes: 900),
        ], using: NameIdentityResolver())

        #expect(groups.map(\.displayName) == ["Big", "Small"])
    }

    @Test("a row with some folders moved reports as partially moved")
    func partialState() {
        let moved = FolderSize(url: FolderCategory.caches.sourceRoot().appending(path: "Google"),
                               bytes: 1_000, category: .caches, isSymlink: true, needsAdmin: false)
        let groups = AppGroup.group(
            [folder("Google", .applicationSupport, bytes: 2_000), moved],
            using: NameIdentityResolver())

        #expect(groups[0].isPartiallyMoved)
        #expect(groups[0].movableFolders.count == 1)
    }
}
