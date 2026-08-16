// swift-tools-version:5.9
import PackageDescription

// SwiftPM builds the core, CLI, standalone app, and test targets. The Makefile assembles
// the legacy `.saver` bundle because SwiftPM has no corresponding product type.
//
// Target layout follows the split between the reusable core and macOS front ends:
//
//   CowsayKit       pure Swift, Foundation only
//   CowsayCLI       cowsaver-cli, for compatibility checks against cowsay
//   CowsaverRender  AppKit rendering shared by both front-ends
//   CowsaverSaver   `.saver` shell, built by the Makefile
//   CowsaverApp     NSApplication shell
//
// CowsaverRender is a SwiftPM target so `swift test` can cover the shared layout and
// rotation behavior, even though the Makefile also compiles it into the saver bundle.
//
// CowsaverSaver is not a SwiftPM target: it produces a loadable bundle, which the Makefile
// builds with `swiftc`.

let package = Package(
    name: "Cowsaver",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CowsayKit", targets: ["CowsayKit"]),
        .library(name: "CowsaverRender", targets: ["CowsaverRender"]),
        .executable(name: "cowsaver-cli", targets: ["CowsayCLI"]),
        .executable(name: "Cowsaver", targets: ["CowsaverApp"]),
    ],
    targets: [
        .target(name: "CowsayKit"),
        .target(name: "CowsaverRender", dependencies: ["CowsayKit"]),
        .executableTarget(name: "CowsayCLI", dependencies: ["CowsayKit"]),
        .executableTarget(name: "CowsaverApp", dependencies: ["CowsayKit", "CowsaverRender"]),
        // Golden fixtures are read by source-tree path. Excluding them avoids treating the
        // checked-in fixture files as SwiftPM resources.
        .testTarget(name: "CowsayKitTests", dependencies: ["CowsayKit"], exclude: ["Golden"]),
        .testTarget(name: "CowsaverRenderTests", dependencies: ["CowsaverRender"]),
    ]
)
