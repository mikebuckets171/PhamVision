// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhamVision",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhamVision", targets: ["PhamVision"]),
        .executable(name: "pv", targets: ["pv"]),
    ],
    targets: [
        .target(name: "PhamVisionCore"),
        .executableTarget(name: "pv", dependencies: ["PhamVisionCore"]),
        .executableTarget(name: "PhamVision", dependencies: ["PhamVisionCore"]),
        .testTarget(name: "PhamVisionCoreTests", dependencies: ["PhamVisionCore"]),
    ]
)
