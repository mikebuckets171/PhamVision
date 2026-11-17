// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhamVision",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhamVision", targets: ["PhamVision"]),
        .executable(name: "pv", targets: ["pv"]),
    ],
    dependencies: [
        // Self-updating from GitHub releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "PhamVisionCore"),
        .executableTarget(name: "pv", dependencies: ["PhamVisionCore"]),
        .executableTarget(
            name: "PhamVision",
            dependencies: ["PhamVisionCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "PhamVisionCoreTests", dependencies: ["PhamVisionCore"]),
    ]
)
