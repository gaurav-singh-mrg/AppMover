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
