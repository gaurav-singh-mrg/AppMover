import Testing
import Foundation
@testable import AppMoverKit

@Suite("Refusing to move a running app's data")
struct RunningAppTests {
    let code = RunningApp(pid: 501, bundleID: "com.microsoft.VSCode",
                          bundlePath: "/Applications/Visual Studio Code.app")
    let finder = RunningApp(pid: 42, bundleID: "com.apple.finder",
                            bundlePath: "/System/Library/CoreServices/Finder.app")

    @Test("blocks when the row resolved to an app bundle that is running")
    func blocksByAppPath() {
        // Arrange / Act
        let blockers = RunningAppCheck.blockers(
            folderNames: ["Code"], appPath: "/Applications/Visual Studio Code.app",
            running: [code, finder])

        // Assert
        #expect(blockers == ["Visual Studio Code"])
    }

    @Test("blocks a cache folder named for the bundle id")
    func blocksByBundleID() {
        let blockers = RunningAppCheck.blockers(
            folderNames: ["com.microsoft.VSCode"], running: [code])

        #expect(blockers == ["Visual Studio Code"])
    }

    @Test("blocks an updater's folder, which suffixes the bundle id it belongs to")
    func blocksBySuffixedBundleID() {
        let blockers = RunningAppCheck.blockers(
            folderNames: ["com.microsoft.VSCode.ShipIt"], running: [code])

        #expect(blockers == ["Visual Studio Code"])
    }

    @Test("blocks a folder named for the app, as Application Support usually is")
    func blocksByAppName() {
        let running = RunningApp(pid: 7, bundleID: "com.feishin.app",
                                 bundlePath: "/Applications/Feishin.app")

        #expect(RunningAppCheck.blockers(folderNames: ["Feishin"], running: [running])
                == ["Feishin"])
    }

    @Test("matches case-insensitively, since folder names are not canonical")
    func matchesCaseInsensitively() {
        #expect(RunningAppCheck.blockers(folderNames: ["COM.MICROSOFT.vscode"], running: [code])
                == ["Visual Studio Code"])
    }

    @Test("allows a folder whose app is not running")
    func allowsQuitApps() {
        #expect(RunningAppCheck.blockers(
            folderNames: ["Code"], appPath: "/Applications/Visual Studio Code.app",
            running: [finder]).isEmpty)
    }

    @Test("does not confuse a same-named folder on an unrelated app")
    func doesNotOvermatch() {
        #expect(RunningAppCheck.blockers(folderNames: ["Spotify"], running: [code, finder])
                .isEmpty)
    }

    @Test("names an app once even when it has several processes running")
    func deduplicatesProcesses() {
        let helper = RunningApp(pid: 502, bundleID: "com.microsoft.VSCode",
                                bundlePath: "/Applications/Visual Studio Code.app")

        #expect(RunningAppCheck.blockers(folderNames: ["com.microsoft.VSCode"],
                                         running: [code, helper]) == ["Visual Studio Code"])
    }

    @Test("a plain folder name never matches a bundle id prefix")
    func plainNamesAreNotBundleIDs() {
        #expect(RunningAppCheck.bundleIDCandidates("Feishin").isEmpty)
        #expect(RunningAppCheck.bundleIDCandidates("com.microsoft.VSCode.ShipIt")
                == ["com.microsoft.vscode.shipit", "com.microsoft.vscode", "com.microsoft"])
    }

    @Test("sees the process holding a file open, whatever the folder is called")
    func findsOpenFileHolders() throws {
        // Arrange: a folder whose name identifies nothing, held open by this process.
        let box = try Sandbox(); defer { box.cleanup() }
        let folder = try box.makeFolder("Code")
        let file = folder.appending(path: "file 0.txt")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        // Act
        let holders = OpenFiles.holders(under: [folder.path])

        // Assert
        #expect(holders.contains(getpid()))
    }

    @Test("reports nobody for a folder no process has open")
    func ignoresUntouchedFolders() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let folder = try box.makeFolder("Untouched")

        #expect(OpenFiles.holders(under: [folder.path]).isEmpty)
    }

    @Test("a sibling with a shared name prefix is not counted as the same folder")
    func prefixMatchIsPathAware() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let folder = try box.makeFolder("App")
        let sibling = try box.makeFolder("AppExtra")
        let handle = try FileHandle(forReadingFrom: sibling.appending(path: "file 0.txt"))
        defer { try? handle.close() }

        #expect(OpenFiles.holders(under: [folder.path]).isEmpty)
    }
}
