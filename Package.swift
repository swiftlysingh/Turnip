// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Turnip",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "Turnip", targets: ["Turnip"]),
    ],
    targets: [
        .binaryTarget(
            name: "DocumentKitCore",
            path: "Artifacts/DocumentKitCore.xcframework"
        ),
        .target(
            name: "Turnip",
            dependencies: ["DocumentKitCore"]
        ),
        .testTarget(
            name: "TurnipTests",
            dependencies: ["Turnip"]
        ),
    ]
)
