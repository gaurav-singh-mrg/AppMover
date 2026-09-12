import Testing
import Foundation
@testable import AppMoverKit

@Suite("Sorting and search")
struct GroupListTests {
    func folder(_ name: String, _ category: FolderCategory = .caches,
                bytes: Int64 = 100, moved: Bool = false) -> FolderSize {
        FolderSize(url: category.sourceRoot().appending(path: name), bytes: bytes,
                   category: category, isSymlink: moved, needsAdmin: false)
    }

    func group(_ name: String, _ folders: [FolderSize]) -> AppGroup {
        AppGroup(id: name.lowercased(), displayName: name, appURL: nil, folders: folders)
    }

    var sample: [AppGroup] {
        [
            group("Visual Studio Code", [folder("com.microsoft.VSCode.ShipIt", bytes: 1_500)]),
            group("Xcode", [folder("Xcode", .developer, bytes: 15_000)]),
            group("ms-playwright", [folder("ms-playwright", bytes: 2_260, moved: true)]),
        ]
    }

    // MARK: - Sorting

    @Test("sorts by size, largest first")
    func sortBySize() {
        let names = GroupList.sorted(sample, by: .size).map(\.displayName)
        #expect(names == ["Xcode", "ms-playwright", "Visual Studio Code"])
    }

    @Test("sorts by name, case-insensitively")
    func sortByName() {
        let names = GroupList.sorted(sample, by: .name).map(\.displayName)
        #expect(names == ["ms-playwright", "Visual Studio Code", "Xcode"])
    }

    @Test("sorts moved folders first, then by size")
    func sortByLocation() {
        let names = GroupList.sorted(sample, by: .location).map(\.displayName)
        #expect(names.first == "ms-playwright")
        #expect(names.dropFirst() == ["Xcode", "Visual Studio Code"])
    }

    @Test("never drops or duplicates a row", arguments: GroupSort.allCases)
    func sortingPreservesEverything(order: GroupSort) {
        let sorted = GroupList.sorted(sample, by: order)
        #expect(sorted.count == sample.count)
        #expect(Set(sorted.map(\.id)) == Set(sample.map(\.id)))
    }

    // MARK: - Search

    @Test("an empty query returns everything")
    func emptyQuery() {
        #expect(GroupList.matching(sample, "   ").count == 3)
    }

    @Test("matches the app's display name")
    func matchesName() {
        #expect(GroupList.matching(sample, "xcode").map(\.displayName) == ["Xcode"])
    }

    @Test("matches a folder inside the row, not just the row's name")
    func matchesInnerFolder() {
        // the row is named "Visual Studio Code"; the folder is com.microsoft.VSCode.ShipIt
        let hits = GroupList.matching(sample, "microsoft").map(\.displayName)
        #expect(hits == ["Visual Studio Code"])
    }

    @Test("matches a category name")
    func matchesCategory() {
        #expect(GroupList.matching(sample, "developer").map(\.displayName) == ["Xcode"])
    }

    @Test("ignores case and accents")
    func ignoresCaseAndAccents() {
        let accented = [group("Café", [folder("Café")])]
        #expect(GroupList.matching(accented, "cafe").count == 1)
        #expect(GroupList.matching(accented, "CAFÉ").count == 1)
    }

    @Test("a query matching nothing returns nothing rather than everything")
    func noMatches() {
        #expect(GroupList.matching(sample, "zzzznope").isEmpty)
    }

    @Test("arrange applies the search before the sort")
    func arrangeCombines() {
        let result = GroupList.arrange(sample, sort: .name, search: "o")
        #expect(result.map(\.displayName) == ["Visual Studio Code", "Xcode"])
    }
}

@Suite("Settings compatibility")
struct SettingsCompatibilityTests {
    @Test("a settings file from an older build keeps its values instead of resetting")
    func decodesOlderFile() throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // no sortOrder key, as written before sorting existed
        try """
            {"destinationFolder":"Stash","destinationUUID":"UUID-7",
             "enabledCategories":["Caches"],"moveApplicationBundles":true}
            """.write(to: url, atomically: true, encoding: .utf8)

        let loaded = Settings.load(from: url)

        #expect(loaded.destinationUUID == "UUID-7")     // the drive choice survives
        #expect(loaded.destinationFolder == "Stash")
        #expect(loaded.moveApplicationBundles)
        #expect(loaded.sortOrder == .size)              // new field takes its default
    }
}

@Suite("Scanner hides what cannot be moved")
struct ScannerFilterTests {
    @Test("omits the ledger directory instead of offering a Move that would fail")
    func hidesLedgerDirectory() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.makeFolder("AppMover")          // our own ledger dir
        try box.makeFolder("RealApp")

        let found = await SpaceScanner(categories: [.applicationSupport], home: box.home)
            .scanAll().map(\.name)

        #expect(found.contains("RealApp"))
        #expect(!found.contains("AppMover"))
    }

    @Test("omits blocklisted roots even when a category would otherwise include them")
    func hidesBlocked() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let containers = box.home.appending(path: "Library/Containers/com.apple.Notes")
        try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
        try box.makeFolder("Fine")

        let found = await SpaceScanner(categories: [.applicationSupport], home: box.home)
            .scanAll().map(\.name)

        #expect(found == ["Fine"])
    }
}

@Suite("Hiding macOS's own folders")
struct SystemFolderTests {
    func folder(_ name: String, moved: Bool = false) -> FolderSize {
        FolderSize(url: FolderCategory.caches.sourceRoot().appending(path: name),
                   bytes: 100, category: .caches, isSymlink: moved, needsAdmin: false)
    }

    func group(_ name: String, _ folders: [FolderSize], app: URL? = nil) -> AppGroup {
        AppGroup(id: name.lowercased(), displayName: name, appURL: app, folders: folders)
    }

    @Test("hides com.apple.* folders no installed app claims")
    func hidesBundleIdentifiers() {
        let groups = [group("com.apple.TCC", [folder("com.apple.TCC")]),
                      group("Feishin", [folder("Feishin")])]
        #expect(GroupList.visible(groups).map(\.displayName) == ["Feishin"])
    }

    @Test("hides Apple system folders that are not bundle identifiers",
          arguments: ["Knowledge", "MobileSync", "AddressBook", "CallHistoryDB",
                      "CallHistoryTransactions", "SyncServices", "Apple"])
    func hidesNamedSystemFolders(name: String) {
        #expect(GroupList.visible([group(name, [folder(name)])]).isEmpty)
    }

    @Test("keeps an Apple folder an installed app claims")
    func keepsXcode() {
        let xcode = group("Xcode", [folder("com.apple.dt.Xcode")],
                          app: URL(filePath: "/Applications/Xcode.app"))
        #expect(GroupList.visible([xcode]).count == 1)
    }

    @Test("never hides a row with something already moved")
    func keepsMovedRows() {
        let moved = group("com.apple.TCC", [folder("com.apple.TCC", moved: true)])
        #expect(GroupList.visible([moved]).count == 1)
    }

    @Test("keeps a row whose folders are not all Apple's")
    func keepsMixedRows() {
        let mixed = group("Thing", [folder("com.apple.Thing"), folder("Thing")])
        #expect(GroupList.visible([mixed]).count == 1)
    }

    @Test("the search denominator drops what is hidden")
    func arrangeHides() {
        let groups = [group("com.apple.TCC", [folder("com.apple.TCC")]),
                      group("Feishin", [folder("Feishin")])]
        #expect(GroupList.arrange(groups, sort: .size).count == 1)
    }
}

@Suite("Apps that need an administrator sort last")
struct AdminSortTests {
    func group(_ name: String, bytes: Int64, admin: Bool) -> AppGroup {
        let folder = FolderSize(url: FolderCategory.caches.sourceRoot().appending(path: name),
                                bytes: bytes, category: .caches,
                                isSymlink: false, needsAdmin: admin)
        return AppGroup(id: name.lowercased(), displayName: name, appURL: nil, folders: [folder])
    }

    @Test("a huge locked app sinks below every app that can just be moved")
    func lockedSinks() {
        let groups = [group("Locked", bytes: 90_000, admin: true),
                      group("Small", bytes: 10, admin: false),
                      group("Big", bytes: 5_000, admin: false)]
        #expect(GroupList.sorted(groups, by: .size).map(\.displayName)
                == ["Big", "Small", "Locked"])
    }

    @Test("locked apps are still ordered among themselves by size")
    func lockedOrderedBySize() {
        let groups = [group("Smaller", bytes: 10, admin: true),
                      group("Larger", bytes: 900, admin: true)]
        #expect(GroupList.sorted(groups, by: .size).map(\.displayName) == ["Larger", "Smaller"])
    }
}
