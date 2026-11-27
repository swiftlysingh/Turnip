// swift-tools-version: 6.2

import Foundation
import PackageDescription

// Populated by `.github/workflows/release.yml` (via `Scripts/set-release-artifact.sh`)
// when cutting a tagged GitHub Release with `DocumentKitCore-<version>.xcframework.zip`.
// Local contributors rebuilding the Rust engine via `Scripts/build-xcframework.sh` can
// override the remote release artifact with `TURNIP_USE_LOCAL_XCFRAMEWORK=1` or
// `TURNIP_LOCAL_XCFRAMEWORK_PATH=<package-relative/path/to/DocumentKitCore.xcframework>`.
let releaseArtifactURL: String? = nil
let releaseArtifactChecksum: String? = nil

let documentKitCoreTarget: Target = {
    let environment = ProcessInfo.processInfo.environment
    if let localPath = environment["TURNIP_LOCAL_XCFRAMEWORK_PATH"], !localPath.isEmpty {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        let prefix = packageRoot.hasSuffix("/") ? packageRoot : packageRoot + "/"
        let resolvedPath = localPath.hasPrefix(prefix)
            ? String(localPath.dropFirst(prefix.count))
            : localPath
        return .binaryTarget(
            name: "DocumentKitCore",
            path: resolvedPath
        )
    }
    if environment["TURNIP_USE_LOCAL_XCFRAMEWORK"] == "1" {
        return .binaryTarget(
            name: "DocumentKitCore",
            path: "Artifacts/DocumentKitCore.xcframework"
        )
    }
    if let url = releaseArtifactURL,
       !url.isEmpty,
       let checksum = releaseArtifactChecksum,
       !checksum.isEmpty
    {
        return .binaryTarget(
            name: "DocumentKitCore",
            url: url,
            checksum: checksum
        )
    }
    return .binaryTarget(
        name: "DocumentKitCore",
        path: "Artifacts/DocumentKitCore.xcframework"
    )
}()

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
        documentKitCoreTarget,
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
