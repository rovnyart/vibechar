// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vibechar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Vibechar", targets: ["Vibechar"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .systemLibrary(name: "CVibechar", path: "Bridge"),
        .executableTarget(
            name: "Vibechar",
            dependencies: ["CVibechar", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedLibrary("vibechar_bridge"), .linkedFramework("AppKit"), .linkedFramework("Security"),
                            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
