// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrinceDevToolsCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SystemHealth", targets: ["SystemHealth"]),
        .library(name: "PanelKit", targets: ["PanelKit"]),
        .library(name: "LocalServers", targets: ["LocalServers"]),
        .library(name: "Containers", targets: ["Containers"])
    ],
    targets: [
        .target(name: "SystemHealth", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "PanelKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LocalServers", dependencies: ["SystemHealth"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "Containers", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "SystemHealthTests", dependencies: ["SystemHealth"]),
        .testTarget(name: "PanelKitTests", dependencies: ["PanelKit"]),
        .testTarget(name: "LocalServersTests", dependencies: ["LocalServers"]),
        .testTarget(name: "ContainersTests", dependencies: ["Containers"], resources: [.process("Resources")])
    ]
)
