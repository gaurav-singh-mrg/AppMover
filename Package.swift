// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppMover",
    platforms: [.macOS(.v14)],
    targets: [
        // Core logic, separated from the UI so it can be tested headlessly.
        .target(name: "AppMoverKit"),
        .executableTarget(name: "AppMover", dependencies: ["AppMoverKit"]),
        .testTarget(name: "AppMoverKitTests", dependencies: ["AppMoverKit"]),
    ]
)
