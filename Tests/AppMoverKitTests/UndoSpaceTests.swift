import Testing
import Foundation
@testable import AppMoverKit

/// A small real volume, so "the disk you are restoring onto" and "the disk the data is on"
/// are genuinely different volumes. The sandbox alone cannot tell them apart -- it puts both
/// on the boot disk, which is exactly the confusion this suite exists to catch.
struct SmallVolume {
    let mountPoint: URL
    private let image: URL

    init?() {
        let id = UUID().uuidString
        image = URL(filePath: NSTemporaryDirectory()).appending(path: "\(id).dmg")
        mountPoint = URL(filePath: NSTemporaryDirectory()).appending(path: "mnt-\(id)")
        guard SmallVolume.run("/usr/bin/hdiutil",
                              ["create", "-size", "20m", "-fs", "APFS",
                               "-volname", "AppMoverTest", "-quiet", image.path]),
              SmallVolume.run("/usr/bin/hdiutil",
                              ["attach", image.path, "-quiet", "-mountpoint", mountPoint.path])
        else { return nil }
    }

    func cleanup() {
        _ = SmallVolume.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
        try? FileManager.default.removeItem(at: image)
        try? FileManager.default.removeItem(at: mountPoint)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

@Suite("Undo checks the disk it restores onto")
struct UndoSpaceTests {
    @Test("refuses to restore onto a disk that cannot hold the data")
    func refusesWhenTheInternalDiskIsFull() throws {
        // Arrange: the folder lives on a 20 MB volume; the external copy sits on the roomy
        // boot disk. Restoring means copying back onto the small one.
        guard let small = SmallVolume() else { return }   // no disk-image support: skip
        defer { small.cleanup() }
        let box = try Sandbox(home: small.mountPoint.appending(path: "home"))
        defer { box.cleanup() }
        let source = try box.makeFolder("Cramped")
        let external = try Sandbox()
        defer { external.cleanup() }
        let (volume, subpath) = try external.destination("Cramped")
        let engine = Engine(allowlist: box.allowlist)
        let record = try engine.move(source: source, toVolume: volume, subpath: subpath)

        // Act / Assert: without the check, ditto would run until the volume filled and leave
        // a partial .appmover.restore that makes the next attempt fail too.
        #expect(throws: EngineError.self) { try engine.undo(record) }

        // The link and the external copy are both untouched, so undo stays possible.
        #expect(try String(contentsOf: source.appending(path: "file 0.txt"), encoding: .utf8)
                == "content-0")
        #expect(!FileManager.default.fileExists(atPath: source.path + ".appmover.restore"))
    }
}
