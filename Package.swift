// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ImagePagerKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "ImagePagerKit",
            targets: ["ImagePagerKit"]
        ),
    ],
    targets: [
        .target(
            name: "ImagePagerKitCore",
            path: "Sources/ImagePagerKit",
            sources: [
                "Cache/DiskImageCache.swift",
                "Cache/MemoryImageCache.swift",
                "Pipeline/ImagePagerPipeline.swift",
                "Pipeline/ImagePagerTypes.swift",
                "Support/ImageCacheKey.swift",
                "Support/ImageCodec.swift",
            ]
        ),
        .target(
            name: "ImagePagerKit",
            dependencies: ["ImagePagerKitCore"],
            path: "Sources/ImagePagerKitUI"
        ),
        .testTarget(
            name: "ImagePagerKitTests",
            dependencies: ["ImagePagerKitCore"]
        ),
    ]
)
