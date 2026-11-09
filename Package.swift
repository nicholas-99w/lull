// swift-tools-version:5.10
// LullCore and LullDaemonKit are plain SwiftPM libraries so their logic can be
// unit-tested with `swift test` without Xcode, launchd, root or the window
// server. The app, daemon and CLI targets live in project.yml (XcodeGen) and
// depend on these products.
import PackageDescription

let package = Package(
    name: "LullCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LullCore", targets: ["LullCore"]),
        // Daemon internals (config loading, persistence, logging, time sync, engine).
        .library(name: "LullDaemonKit", targets: ["LullDaemonKit"]),
        // Agent UI: SwiftUI views, view model, overlay/panel window controllers.
        .library(name: "LullAgentKit", targets: ["LullAgentKit"]),
    ],
    targets: [
        .target(name: "LullCore", path: "Sources/LullCore"),
        .target(name: "LullDaemonKit", dependencies: ["LullCore"], path: "Sources/LullDaemonKit"),
        .target(name: "LullAgentKit", dependencies: ["LullCore"], path: "Sources/LullAgentKit"),
        .testTarget(name: "LullCoreTests", dependencies: ["LullCore"], path: "Tests/LullCoreTests"),
        .testTarget(name: "LullDaemonKitTests", dependencies: ["LullDaemonKit"], path: "Tests/LullDaemonKitTests"),
        // Never creates windows: tests must not put an overlay on the dev Mac.
        .testTarget(name: "LullAgentKitTests", dependencies: ["LullAgentKit"], path: "Tests/LullAgentKitTests"),
    ]
)
