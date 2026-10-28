// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "SVGAPlayer-swift",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SVGAPlayer-swift",
            targets: ["SVGAPlayer_swift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        .target(
            name: "SVGAPlayer_swift",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                // 库默认 nonisolated；不要继承调用方或 demo 的 MainActor 隔离。
                .defaultIsolation(nil),
            ]
        ),
        .testTarget(
            name: "SVGAPlayer_swiftTests",
            dependencies: ["SVGAPlayer_swift"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .defaultIsolation(nil),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
