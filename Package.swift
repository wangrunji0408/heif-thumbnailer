// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageThumbnailer",
    platforms: [
        .macOS(.v11),
        .iOS(.v12),
    ],
    products: [
        .library(
            name: "ImageThumbnailer",
            targets: ["ImageThumbnailer"]
        ),
        .executable(
            name: "ImageThumbnailerCLI",
            targets: ["ImageThumbnailerCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ImageThumbnailer",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "ImageThumbnailerCLI",
            dependencies: [
                "ImageThumbnailer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ImageThumbnailerTests",
            dependencies: ["ImageThumbnailer"],
            resources: [.copy("Resources")]
        ),
    ]
)
