// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ui-test-agent",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "amoo-ext-moq", targets: ["AmooExtMoq"]),
        .library(name: "MoqBridge", targets: ["MoqBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/maniramezan/SwiftCommons", exact: "0.20.0", traits: []),
    ],
    targets: [
        .target(
            name: "MoqBridge",
            dependencies: [
                .product(name: "SwiftCommons", package: "SwiftCommons")
            ]
        ),
        .executableTarget(
            name: "AmooExtMoq",
            dependencies: [
                "MoqBridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MoqBridgeTests",
            dependencies: ["MoqBridge"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
