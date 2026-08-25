// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TurnipBenchmarks",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "turnip-benchmark",
            targets: ["TurnipBenchmark"]
        ),
    ],
    dependencies: [
        .package(name: "Turnip", path: ".."),
    ],
    targets: [
        .target(
            name: "BenchmarkCore",
            dependencies: [
                .product(name: "Turnip", package: "Turnip"),
            ],
            swiftSettings: [
                .define("TURNIP_BENCHMARK_RELEASE", .when(configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "TurnipBenchmark",
            dependencies: ["BenchmarkCore"]
        ),
        .testTarget(
            name: "BenchmarkCoreTests",
            dependencies: [
                "BenchmarkCore",
                .product(name: "Turnip", package: "Turnip"),
            ]
        ),
    ]
)
