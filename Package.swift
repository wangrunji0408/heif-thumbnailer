// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HEICThumbnailer",
    platforms: [
        .macOS(.v11),
        .iOS(.v12),
    ],
    products: [
        .library(
            name: "HEICThumbnailer",
            targets: ["HEICThumbnailer"]
        ),
        .executable(
            name: "HEICThumbnailerCLI",
            targets: ["HEICThumbnailerCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HEICThumbnailer",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "HEICThumbnailerCLI",
            dependencies: [
                "HEICThumbnailer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "HEICThumbnailerTests",
            dependencies: ["HEICThumbnailer"],
            resources: [.copy("Resources")]
        ),
    ]
)
