// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlamoKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlamoTokenizer", targets: ["PlamoTokenizer"]),
        .library(name: "PlamoKit", targets: ["PlamoKit"]),
        .executable(name: "plamo-cli", targets: ["plamo-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0")
    ],
    targets: [
        // Pure Swift port of PLaMo's Aho-Corasick unigram tokenizer (no MLX dependency).
        .target(name: "PlamoTokenizer"),
        // PLaMo 3 model, translation engine, model catalog and downloader.
        .target(
            name: "PlamoKit",
            dependencies: [
                "PlamoTokenizer",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
        .executableTarget(name: "plamo-cli", dependencies: ["PlamoKit"]),
        .testTarget(
            name: "PlamoTokenizerTests",
            dependencies: ["PlamoTokenizer"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "PlamoKitTests", dependencies: ["PlamoKit"]),
    ]
)
