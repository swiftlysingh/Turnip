// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DocumentKitBenchmarks",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "documentkit-benchmark",
            targets: ["DocumentKitBenchmark"]
        ),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "DocumentKitBenchmark",
            dependencies: [
                .product(name: "DocumentKit", package: "DocumentKit"),
            ]
        ),
    ]
)
