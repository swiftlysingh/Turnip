// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DocumentKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DocumentKit", targets: ["DocumentKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "DocumentKitCore",
            path: "Artifacts/DocumentKitCore.xcframework"
        ),
        .target(
            name: "DocumentKit",
            dependencies: ["DocumentKitCore"]
        ),
        .testTarget(
            name: "DocumentKitTests",
            dependencies: ["DocumentKit"]
        ),
    ]
)
