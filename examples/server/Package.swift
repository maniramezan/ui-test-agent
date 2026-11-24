// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "example-server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "example-server", targets: ["ExampleServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.4"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.4"),
        .package(url: "https://github.com/swift-server/swift-openapi-hummingbird", exact: "2.1.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", exact: "2.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/maniramezan/SwiftCommons", exact: "0.21.0", traits: []),
    ],
    targets: [
        .target(
            name: "ExampleBackend",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "SwiftCommons", package: "SwiftCommons"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .executableTarget(
            name: "ExampleServer",
            dependencies: [
                "ExampleBackend",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ExampleBackendTests",
            dependencies: [
                "ExampleBackend",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
