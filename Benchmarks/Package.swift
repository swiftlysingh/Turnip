// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DocumentKitBenchmarks",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "documentkit-benchmark",
            targets: ["DocumentKitBenchmark"]
        ),
    ],
    dependencies: [
        .package(name: "DocumentKit", path: ".."),
    ],
    targets: [
        .target(
            name: "BenchmarkCore",
            dependencies: [
                .product(name: "DocumentKit", package: "DocumentKit"),
            ],
            swiftSettings: [
                .define("DOCUMENTKIT_BENCHMARK_RELEASE", .when(configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "DocumentKitBenchmark",
            dependencies: ["BenchmarkCore"]
        ),
        .testTarget(
            name: "BenchmarkCoreTests",
            dependencies: [
                "BenchmarkCore",
                .product(name: "DocumentKit", package: "DocumentKit"),
            ]
        ),
    ]
)
