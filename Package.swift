// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DiskGuard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DiskGuardCore",
            targets: ["DiskGuardCore"]
        ),
        .executable(
            name: "DiskGuard",
            targets: ["DiskGuard"]
        )
    ],
    targets: [
        .target(
            name: "DiskGuardCore"
        ),
        .executableTarget(
            name: "DiskGuard",
            dependencies: ["DiskGuardCore"],
            resources: [
                .copy("Resources/Pets")
            ]
        ),
        .testTarget(
            name: "DiskGuardCoreTests",
            dependencies: ["DiskGuardCore"]
        )
    ]
)
