// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ZoomableImageManager",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "ZoomableImageManager",
            targets: ["ZoomableImageManager"]
        ),
    ],
    targets: [
        .target(
            name: "ZoomableImageManagerCore",
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
            name: "ZoomableImageManager",
            dependencies: ["ZoomableImageManagerCore"],
            path: "Sources/ImagePagerKitUI"
        ),
        .testTarget(
            name: "ZoomableImageManagerTests",
            dependencies: ["ZoomableImageManagerCore"],
            path: "Tests/ImagePagerKitTests"
        ),
    ]
)
