// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vibechar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Vibechar", targets: ["Vibechar"])],
    targets: [
        .systemLibrary(name: "CVibechar", path: "Bridge"),
        .executableTarget(
            name: "Vibechar",
            dependencies: ["CVibechar"],
            linkerSettings: [.linkedLibrary("vibechar_bridge"), .linkedFramework("AppKit")]
        ),
    ]
)
