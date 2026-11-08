// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MimiuchiCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MimiuchiCore", targets: ["MimiuchiCore"])],
    targets: [
        // App logic without UI/MLX dependencies (unit-testable with `swift test`).
        .target(name: "MimiuchiCore"),
        .testTarget(name: "MimiuchiCoreTests", dependencies: ["MimiuchiCore"]),
    ]
)
