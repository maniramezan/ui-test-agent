// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ui-test-agent",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "amoo-ext-moq", targets: ["AmooExtMoq"]),
        .executable(name: "amoo-ext-auth", targets: ["AmooExtAuth"]),
        .executable(name: "uita", targets: ["Uita"]),
        .library(name: "MoqBridge", targets: ["MoqBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/maniramezan/SwiftCommons", exact: "0.20.0", traits: []),
    ],
    targets: [
        .target(name: "ExtensionKit"),
        .target(
            name: "MoqBridge",
            dependencies: [
                "ExtensionKit",
                .product(name: "SwiftCommons", package: "SwiftCommons"),
            ]
        ),
        .executableTarget(
            name: "AmooExtMoq",
            dependencies: [
                "MoqBridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "AuthBridge",
            dependencies: [
                "ExtensionKit",
                .product(name: "SwiftCommons", package: "SwiftCommons"),
            ]
        ),
        .executableTarget(
            name: "AmooExtAuth",
            dependencies: [
                "AuthBridge",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "UitaKit",
            dependencies: [
                "ExtensionKit",
                .product(name: "SwiftCommons", package: "SwiftCommons"),
            ]
        ),
        .executableTarget(
            name: "Uita",
            dependencies: [
                "UitaKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "UitaKitTests",
            dependencies: ["UitaKit"]
        ),
        .testTarget(
            name: "AuthBridgeTests",
            dependencies: ["AuthBridge"]
        ),
        .testTarget(
            name: "MoqBridgeTests",
            dependencies: ["MoqBridge"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
