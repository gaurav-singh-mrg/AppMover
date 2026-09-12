import Testing
import Foundation
@testable import AppMoverKit

@Suite("App identity")
struct AppIdentityResolverTests {
    /// Builds a throwaway /Applications containing real .app bundles, so the resolver is
    /// exercised through the same Info.plist reads it does on a live machine.
    func fixture(_ apps: [(name: String, bundleID: String?)]) throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "identity-\(UUID().uuidString)")
        for app in apps {
            let contents = root.appending(path: "\(app.name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            guard let id = app.bundleID else { continue }
            try (["CFBundleIdentifier": id] as NSDictionary)
                .write(to: contents.appending(path: "Info.plist"))
        }
        return root
    }

    func folder(_ name: String, _ category: FolderCategory = .applicationSupport) -> FolderSize {
        FolderSize(url: URL(filePath: "/Users/x/Library/\(category.rawValue)/\(name)"),
                   bytes: 1024, category: category, isSymlink: false, needsAdmin: false)
    }

    @Test("punctuation and spacing are ignored on both sides of the match")
    func squashedNameMatch() throws {
        let root = try fixture([("Boom 3D", "com.globaldelight.boom3d"),
                                ("Arduino IDE", "cc.arduino.IDE2")])
        let resolver = AppIdentityResolver(searchPaths: [root])

        #expect(resolver.identity(for: folder("Boom3D")).displayName == "Boom 3D")
        #expect(resolver.identity(for: folder("arduino-ide")).displayName == "Arduino IDE")
    }

    @Test("a bundle identifier resolves, updater suffix and all")
    func bundleIDMatch() throws {
        let root = try fixture([("Visual Studio Code", "com.microsoft.VSCode")])
        let resolver = AppIdentityResolver(searchPaths: [root])

        let identity = resolver.identity(for: folder("com.microsoft.VSCode.ShipIt", .caches))
        #expect(identity.displayName == "Visual Studio Code")
        #expect(identity.appURL != nil)
    }

    @Test("an alias reaches folders whose name shares nothing with the app")
    func aliasMatch() throws {
        let root = try fixture([("Visual Studio Code", "com.microsoft.VSCode")])
        let resolver = AppIdentityResolver(searchPaths: [root])

        let identity = resolver.identity(for: folder("Code"))
        #expect(identity.displayName == "Visual Studio Code")
        #expect(identity.appURL != nil)
    }

    @Test("aliased folders share one row even when the app is not installed")
    func aliasGroupsWithoutApp() throws {
        let resolver = AppIdentityResolver(searchPaths: [try fixture([])])
        let developer = FolderCategory.developer
        let group = AppGroup.group(
            [folder("Xcode", developer), folder("CoreSimulator", developer),
             folder("XCTestDevices", developer)], using: resolver)

        #expect(group.count == 1)
        #expect(group[0].displayName == "Xcode")
        #expect(group[0].appURL == nil)
    }

    @Test("a longer folder name resolves to the app it starts with")
    func prefixMatch() throws {
        let resolver = AppIdentityResolver(searchPaths: [try fixture([("Telegram", "com.tdesktop.Telegram")])])
        #expect(resolver.identity(for: folder("Telegram Desktop")).displayName == "Telegram")
    }

    @Test("a short app name never claims a longer folder by prefix")
    func prefixRequiresLength() throws {
        let resolver = AppIdentityResolver(searchPaths: [try fixture([("Code", "com.example.code")])])
        // "code" is 4 characters, under the threshold, so "CodeRunner" stays unresolved.
        #expect(resolver.identity(for: folder("CodeRunner")).appURL == nil)
    }

    @Test("two apps that squash to one key resolve to neither")
    func ambiguousNamesAreDropped() throws {
        let root = try fixture([("Boom 3D", "com.a.boom"), ("Boom3D", "com.b.boom")])
        let resolver = AppIdentityResolver(searchPaths: [root])

        let identity = resolver.identity(for: folder("boom-3d"))
        #expect(identity.appURL == nil)
        #expect(identity.displayName == "boom-3d")
    }

    @Test("an unidentified folder keeps its own row rather than sharing a bucket")
    func unresolvedFoldersStaySeparate() throws {
        let resolver = AppIdentityResolver(searchPaths: [try fixture([])])
        let groups = AppGroup.group(
            [folder("com.apple.wallpaper"), folder("navidrome-ui")], using: resolver)

        #expect(groups.count == 2)
    }
}
