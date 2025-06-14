// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HeifThumbnailer",
    platforms: [
        .macOS(.v11),
        .iOS(.v12),
    ],
    products: [
        .library(
            name: "HeifThumbnailer",
            targets: ["HeifThumbnailer"]
        ),
        .executable(
            name: "HeifThumbnailerCLI",
            targets: ["HeifThumbnailerCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HeifThumbnailer",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "HeifThumbnailerCLI",
            dependencies: [
                "HeifThumbnailer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HeifThumbnailerTests",
            dependencies: ["HeifThumbnailer"],
            resources: [.copy("Resources")]
        ),
    ]
)
