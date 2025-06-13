// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HEICThumbnailExtractor",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "HEICThumbnailExtractor",
            targets: ["HEICThumbnailExtractor"]
        ),
        .executable(
            name: "HEICThumbnailCLI",
            targets: ["HEICThumbnailCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HEICThumbnailExtractor",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "HEICThumbnailCLI",
            dependencies: [
                "HEICThumbnailExtractor",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HEICThumbnailExtractorTests",
            dependencies: ["HEICThumbnailExtractor"],
            resources: [.copy("Resources")]
        ),
    ]
)
