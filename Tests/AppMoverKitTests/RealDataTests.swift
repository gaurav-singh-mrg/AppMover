import Testing
import Foundation
@testable import AppMoverKit

/// End-to-end check against a real folder on a real external volume.
///
/// Opt-in, because it moves actual data. Run with:
///   APPMOVER_REAL_FOLDER="$HOME/Library/Application Support/feishin" \
///   APPMOVER_REAL_VOLUME=/Volumes/MicroSD swift test --filter RealData
@Suite("RealData", .enabled(if: ProcessInfo.processInfo.environment["APPMOVER_REAL_FOLDER"] != nil))
struct RealDataTests {

    @Test("moves and restores a real folder on a real external volume, byte for byte")
    func realRoundtrip() throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(filePath: try #require(env["APPMOVER_REAL_FOLDER"]))
        let mount = URL(filePath: try #require(env["APPMOVER_REAL_VOLUME"]))
        let volume = try #require(Volume(mountPoint: mount))
        let engine = Engine()

        let before = try Manifest.scan(source)
        let beforeHash = try treeHash(source)

        let record = try engine.move(
            source: source, toVolume: volume, subpath: "AppMoverTest/\(source.lastPathComponent)")

        // reads through the symlink must be identical
        #expect(try Manifest.scan(source) == before)
        #expect(try treeHash(source) == beforeHash)
        #expect(onInternalDisk(source) == 0)      // space actually freed

        try engine.undo(record)

        #expect(try Manifest.scan(source) == before)
        #expect(try treeHash(source) == beforeHash)
        #expect(try #require(record.currentTarget()).path.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: record.currentTarget()!.path))
    }

    /// md5 of every file's contents plus its relative path, order-independent.
    func treeHash(_ root: URL) throws -> String {
        let (_, out) = try shell("/bin/sh", ["-c",
            "cd \(root.path.replacingOccurrences(of: " ", with: "\\ ")) && " +
            "find . -type f -exec md5 -q {} + | sort | md5 -q"])
        return out
    }

    func onInternalDisk(_ url: URL) -> Int64 {
        let (_, out) = (try? shell("/usr/bin/du", ["-skx", url.path])) ?? (1, "0")
        return Int64(out.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
    }

    func shell(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process(); p.executableURL = URL(filePath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@Suite("RealSpeed", .enabled(if: ProcessInfo.processInfo.environment["APPMOVER_REAL_VOLUME"] != nil))
struct RealSpeedTests {
    @Test("measures a real volume's sustained write speed")
    func measuresVolume() throws {
        let mount = URL(filePath:
            try #require(ProcessInfo.processInfo.environment["APPMOVER_REAL_VOLUME"]))
        let volume = try #require(Volume(mountPoint: mount))

        let speed = try DriveSpeedTester().measure(volume)

        print("MEASURED \(volume.name): \(speed.summary) — slow: \(speed.isSlow)")
        #expect(speed.megabytesPerSecond > 0)
        #expect(speed.megabytesPerSecond < 20_000)   // sanity: not measuring RAM
        // probe file must not be left behind
        #expect(!FileManager.default.fileExists(
            atPath: mount.appending(path: ".appmover-speedtest").path))
    }
}
