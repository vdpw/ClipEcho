// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ClipEchoNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipEchoCore", targets: ["ClipEchoCore"]),
        .executable(name: "ClipEcho", targets: ["ClipEcho"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "ClipEchoCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ClipEcho", dependencies: ["ClipEchoCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "ClipEchoCoreTests", dependencies: ["ClipEchoCore", "CSQLite"]),
    ],
    swiftLanguageModes: [.v6]
)
