import Testing
import Foundation
@testable import AppMoverKit

@Suite("Settings")
struct SettingsTests {
    @Test("defaults to data categories with application bundles switched off")
    func safeDefaults() {
        let settings = Settings()
        #expect(!settings.moveApplicationBundles)
        #expect(!settings.activeCategories.contains(.applications))
        #expect(settings.activeCategories.contains(.applicationSupport))
    }

    @Test("application bundles stay inactive until explicitly enabled, even if listed")
    func bundlesGated() {
        let listed = Settings(enabledCategories: [.applications, .caches])
        #expect(!listed.activeCategories.contains(.applications))

        let enabled = listed.with { $0.moveApplicationBundles = true }
        #expect(enabled.activeCategories.contains(.applications))
    }

    @Test("changes return a new value and never mutate the original")
    func immutableUpdates() {
        let original = Settings()
        let updated = original.with { $0.destinationFolder = "Elsewhere" }
        #expect(original.destinationFolder == "AppMover")
        #expect(updated.destinationFolder == "Elsewhere")
    }

    @Test("survives a save/load roundtrip")
    func roundtrip() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = Settings(enabledCategories: [.caches], destinationUUID: "UUID-9",
                                destinationFolder: "Stash", moveApplicationBundles: true)
        try settings.save(to: url)
        #expect(Settings.load(from: url) == settings)
    }

    @Test("a corrupt file falls back to defaults rather than throwing")
    func toleratesBadFile() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "nonsense".write(to: url, atomically: true, encoding: .utf8)
        #expect(Settings.load(from: url) == Settings())
    }
}

@Suite("Destination layout")
struct DestinationLayoutTests {
    @Test("files each folder under its category on the drive", arguments: [
        (FolderCategory.applicationSupport, "AppMover/Application Support/Code"),
        (FolderCategory.caches, "AppMover/Caches/Code"),
        (FolderCategory.developer, "AppMover/Developer/Code"),
    ])
    func perCategoryLayout(category: FolderCategory, expected: String) {
        let folder = FolderSize(url: category.sourceRoot().appending(path: "Code"),
                                bytes: 1, category: category, isSymlink: false, needsAdmin: false)
        #expect(folder.destinationSubpath(root: "AppMover") == expected)
    }

    @Test("honours a custom destination folder name")
    func customRoot() {
        let folder = FolderSize(url: URL(filePath: "/x/Code"), bytes: 1,
                                category: .caches, isSymlink: false, needsAdmin: false)
        #expect(folder.destinationSubpath(root: "Stash") == "Stash/Caches/Code")
    }
}

@Suite("Allowlist follows settings but never widens")
struct AllowlistSettingsTests {
    @Test("a disabled category is not movable")
    func disabledCategory() throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let only = Allowlist(home: home, categories: [.caches])
        #expect(!only.isAllowed(home.appending(path: "Library/Application Support/Code")))
        #expect(only.isAllowed(home.appending(path: "Library/Caches/Code")))
    }

    @Test("blocked paths stay blocked no matter which categories are enabled")
    func blocklistIsFixed() throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let everything = Allowlist(home: home, categories: FolderCategory.allCases)
        for blocked in ["Containers/com.apple.Notes", "Group Containers/g", "Keychains/k"] {
            #expect(!everything.isAllowed(home.appending(path: "Library/\(blocked)")))
        }
    }

    @Test("only direct children may move, never something nested deeper")
    func directChildrenOnly() throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let list = Allowlist(home: home)
        #expect(list.isAllowed(home.appending(path: "Library/Caches/Code")))
        #expect(!list.isAllowed(home.appending(path: "Library/Caches/Code/Deep/Nested")))
    }
}

@Suite("Current location")
struct CurrentLocationTests {
    @Test("an unmoved folder reports its own path")
    func unmoved() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let dir = try box.makeFolder("Here")
        let folder = FolderSize(url: dir, bytes: 1, category: .applicationSupport,
                                isSymlink: false, needsAdmin: false)

        #expect(folder.currentLocation == dir)
        #expect(!folder.isRelocated)
    }

    @Test("a moved folder reports where the data actually is")
    func moved() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Moved")
        let (volume, subpath) = try box.destination("Moved")
        let record = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath)

        let folder = FolderSize(url: source, bytes: 1, category: .applicationSupport,
                                isSymlink: true, needsAdmin: false)

        #expect(folder.currentLocation.path == record.currentTarget()?.path)
        #expect(folder.isRelocated)
    }

    @Test("still reports the target when the drive is missing, so the data can be found")
    func targetMissing() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let source = try box.makeFolder("Gone")
        let (volume, subpath) = try box.destination("Gone")
        let record = try Engine(allowlist: box.allowlist).move(
            source: source, toVolume: volume, subpath: subpath)
        try FileManager.default.removeItem(at: #require(record.currentTarget()))

        let folder = FolderSize(url: source, bytes: 1, category: .applicationSupport,
                                isSymlink: true, needsAdmin: false)

        #expect(folder.isRelocated)
        #expect(folder.currentLocation.lastPathComponent == "Gone")
    }
}
